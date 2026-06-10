#!/usr/bin/env bash
set -euo pipefail

# Build a PR-friendly Markdown summary from a Jacoco XML report.
#
# The workflow already decides whether this script should run. This script only:
# 1. validates the required GitHub Actions environment,
# 2. parses jacoco.xml into a simple tab-delimited intermediate format,
# 3. renders the Markdown used by the PR sticky comment and step summary, and
# 4. exposes outputs consumed by the following github-script step.
#
# Intermediate records produced by parse_jacoco_xml:
#   T <metric> <covered> <missed>
#   P <missed_lines> <package> <line_pct> <branch_pct> <method_pct>
#
# Package rows are sorted by missed lines descending so the comment highlights
# the packages with the largest immediate coverage gap first.

require_env() {
  : "${COMMENT_FILE:?COMMENT_FILE is required}"
  : "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
  : "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
  : "${JACOCO_REPORT_DIRECTORY:?JACOCO_REPORT_DIRECTORY is required}"
}

cleanup_temp_files() {
  if [ "${#temp_files[@]}" -gt 0 ]; then
    rm -f "${temp_files[@]}"
  fi
}

write_github_output() {
  local name="$1"
  local value="$2"

  echo "$name=$value" >> "$GITHUB_OUTPUT"
}

jacoco_xml_file() {
  printf '%s/jacoco.xml' "${JACOCO_REPORT_DIRECTORY%/}"
}

has_jacoco_report() {
  local xml_file="$1"

  [ -f "$xml_file" ] && grep -q '<report' "$xml_file"
}

ensure_comment_directory() {
  mkdir -p "$(dirname "$COMMENT_FILE")"
}

write_empty_comment() {
  ensure_comment_directory
  : > "$COMMENT_FILE"
}

coverage_percent() {
  local covered="$1"
  local missed="$2"
  local total=$((covered + missed))

  if [ "$total" -eq 0 ]; then
    printf 'n/a'
  else
    awk -v covered="$covered" -v total="$total" 'BEGIN { printf "%.2f%%", covered * 100 / total }'
  fi
}

metric_row() {
  local metric="$1"
  local covered="$2"
  local missed="$3"
  local total=$((covered + missed))

  printf '| %s | %s | %s | %s | %s |\n' "$metric" "$covered" "$missed" "$total" "$(coverage_percent "$covered" "$missed")"
}

markdown_escape() {
  local value="$1"

  value="${value//$'\n'/ }"
  value="${value//|/\\|}"
  printf '%s' "$value"
}

normalized_package_limit() {
  local package_limit="${JACOCO_PACKAGE_ROW_LIMIT:-20}"

  if ! [[ "$package_limit" =~ ^[0-9]+$ ]]; then
    package_limit=20
  fi

  printf '%s' "$package_limit"
}

parse_jacoco_xml() {
  local xml_file="$1"
  local parsed_file="$2"

  # Jacoco XML has the counters needed here on <report> and <package> nodes.
  # Splitting adjacent tags keeps the awk state machine small and avoids adding
  # Python, jq, or xmllint dependencies to the reusable workflow runner image.
  sed 's/></>\n</g' "$xml_file" | awk '
    function attr(line, name,    pattern, value) {
      pattern = name "=\"[^\"]*\""
      if (match(line, pattern)) {
        value = substr(line, RSTART + length(name) + 2, RLENGTH - length(name) - 3)
        return value
      }
      return ""
    }

    function percent(covered, missed,    total) {
      total = covered + missed
      if (total == 0) {
        return "n/a"
      }
      return sprintf("%.2f%%", covered * 100 / total)
    }

    function package_name(raw) {
      gsub("/", ".", raw)
      if (raw == "") {
        return "(default)"
      }
      return raw
    }

    function emit_package(name,    line_covered, line_missed, branch_covered, branch_missed, method_covered, method_missed) {
      line_covered = package_covered[name, "LINE"] + 0
      line_missed = package_missed[name, "LINE"] + 0
      branch_covered = package_covered[name, "BRANCH"] + 0
      branch_missed = package_missed[name, "BRANCH"] + 0
      method_covered = package_covered[name, "METHOD"] + 0
      method_missed = package_missed[name, "METHOD"] + 0

      if (line_covered + line_missed + branch_covered + branch_missed + method_covered + method_missed > 0) {
        print "P\t" line_missed "\t" name "\t" percent(line_covered, line_missed) "\t" percent(branch_covered, branch_missed) "\t" percent(method_covered, method_missed)
      }
    }

    {
      line = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line == "") {
        next
      }

      if (line ~ /^<counter[[:space:]>]/) {
        type = attr(line, "type")
        missed = attr(line, "missed") + 0
        covered = attr(line, "covered") + 0

        if (depth == 1) {
          report_covered[type] = covered
          report_missed[type] = missed
        } else if (depth == 2 && current_package != "") {
          package_covered[current_package, type] = covered
          package_missed[current_package, type] = missed
        }
        next
      }

      if (line ~ /^<\//) {
        if (line ~ /^<\/package>/) {
          current_package = ""
        }
        depth--
        if (depth < 0) {
          depth = 0
        }
        next
      }

      if (line ~ /^<[^!?\/][^>]*\/>$/) {
        next
      }

      if (line ~ /^<[^!?\/][^>]*>/) {
        depth++
        if (line ~ /^<package[[:space:]>]/) {
          current_package = package_name(attr(line, "name"))
          packages[current_package] = 1
        }
      }
    }

    END {
      print "T\tLINE\t" report_covered["LINE"] + 0 "\t" report_missed["LINE"] + 0
      print "T\tBRANCH\t" report_covered["BRANCH"] + 0 "\t" report_missed["BRANCH"] + 0
      print "T\tMETHOD\t" report_covered["METHOD"] + 0 "\t" report_missed["METHOD"] + 0
      print "T\tINSTRUCTION\t" report_covered["INSTRUCTION"] + 0 "\t" report_missed["INSTRUCTION"] + 0

      for (name in packages) {
        emit_package(name)
      }
    }
  ' > "$parsed_file"
}

reset_totals() {
  line_covered=0
  line_missed=0
  branch_covered=0
  branch_missed=0
  method_covered=0
  method_missed=0
  instruction_covered=0
  instruction_missed=0
}

load_total_record() {
  local metric="$1"
  local covered="$2"
  local missed="$3"

  case "$metric" in
    LINE)
      line_covered="$covered"
      line_missed="$missed"
      ;;
    BRANCH)
      branch_covered="$covered"
      branch_missed="$missed"
      ;;
    METHOD)
      method_covered="$covered"
      method_missed="$missed"
      ;;
    INSTRUCTION)
      instruction_covered="$covered"
      instruction_missed="$missed"
      ;;
  esac
}

append_package_record() {
  local package_file="$1"
  local missed_lines="$2"
  local package_name="$3"
  local lines_pct="$4"
  local branches_pct="$5"
  local methods_pct="$6"

  printf '%s\t%s\t%s\t%s\t%s\n' "$missed_lines" "$package_name" "$lines_pct" "$branches_pct" "$methods_pct" >> "$package_file"
}

load_parsed_report() {
  local parsed_file="$1"
  local package_file="$2"

  reset_totals
  : > "$package_file"

  while IFS=$'\t' read -r record_type first second third fourth fifth; do
    if [ "$record_type" = "T" ]; then
      load_total_record "$first" "$second" "$third"
    elif [ "$record_type" = "P" ]; then
      append_package_record "$package_file" "$first" "$second" "$third" "$fourth" "$fifth"
    fi
  done < "$parsed_file"
}

sort_package_records() {
  local package_file="$1"
  local sorted_package_file="$2"

  LC_ALL=C sort -t $'\t' -k1,1nr -k2,2 "$package_file" > "$sorted_package_file"
}

line_count() {
  local file="$1"

  wc -l < "$file" | tr -d ' '
}

artifact_markdown_line() {
  if [ -n "${ARTIFACT_URL:-}" ]; then
    printf -- '- HTML report: [workflow artifact](%s)' "$ARTIFACT_URL"
  else
    printf -- '- HTML report: not uploaded'
  fi
}

write_comment_header() {
  echo '### SBT Jacoco coverage'
  echo ''
  echo "- Working directory: \`${WORKING_DIRECTORY:-.}\`"
  echo "- Command: \`${COVERAGE_COMMAND:-}\`"
  echo "- Result: \`${COVERAGE_RESULT:-skipped}\`"
  artifact_markdown_line
  echo ''
  echo ''
}

write_totals_table() {
  echo '#### Totals'
  echo ''
  echo '| Metric | Covered | Missed | Total | Coverage |'
  echo '| --- | ---: | ---: | ---: | ---: |'
  metric_row 'Lines' "$line_covered" "$line_missed"
  metric_row 'Branches' "$branch_covered" "$branch_missed"
  metric_row 'Methods' "$method_covered" "$method_missed"
  metric_row 'Instructions' "$instruction_covered" "$instruction_missed"
}

write_package_rows() {
  local sorted_package_file="$1"
  local package_limit="$2"

  visible_package_count=0
  while IFS=$'\t' read -r missed_lines package_name lines_pct branches_pct methods_pct; do
    if [ "$visible_package_count" -ge "$package_limit" ]; then
      break
    fi
    printf '| %s | %s | %s | %s |\n' "$(markdown_escape "$package_name")" "$lines_pct" "$branches_pct" "$methods_pct"
    visible_package_count=$((visible_package_count + 1))
  done < "$sorted_package_file"
}

write_packages_table() {
  local sorted_package_file="$1"
  local package_count="$2"
  local package_limit="$3"

  if [ "$package_count" -eq 0 ] || [ "$package_limit" -eq 0 ]; then
    return
  fi

  echo ''
  echo '#### Packages'
  echo ''
  echo '| Package | Lines | Branches | Methods |'
  echo '| --- | ---: | ---: | ---: |'

  write_package_rows "$sorted_package_file" "$package_limit"

  if [ "$package_count" -gt "$visible_package_count" ]; then
    echo ''
    echo "Showing $visible_package_count of $package_count packages, sorted by missed lines."
  fi
}

write_summary_comment() {
  local sorted_package_file="$1"
  local package_count="$2"
  local package_limit="$3"

  ensure_comment_directory
  {
    write_comment_header
    write_totals_table
    write_packages_table "$sorted_package_file" "$package_count" "$package_limit"
  } > "$COMMENT_FILE"
}

publish_script_result() {
  if [ -s "$COMMENT_FILE" ]; then
    cat "$COMMENT_FILE" >> "$GITHUB_STEP_SUMMARY"
    write_github_output "has_structured_summary" "true"
  else
    echo "No Jacoco XML report was found." >> "$GITHUB_STEP_SUMMARY"
    write_github_output "has_structured_summary" "false"
  fi
}

main() {
  local xml_file
  local package_limit
  local parsed_file
  local package_file
  local sorted_package_file
  local package_count

  require_env
  write_github_output "comment_file" "$COMMENT_FILE"

  xml_file="$(jacoco_xml_file)"
  package_limit="$(normalized_package_limit)"

  if ! has_jacoco_report "$xml_file"; then
    write_empty_comment
    publish_script_result
    return
  fi

  parsed_file="$(mktemp)"
  package_file="$(mktemp)"
  sorted_package_file="$(mktemp)"
  temp_files=("$parsed_file" "$package_file" "$sorted_package_file")
  trap cleanup_temp_files EXIT

  parse_jacoco_xml "$xml_file" "$parsed_file"
  load_parsed_report "$parsed_file" "$package_file"
  sort_package_records "$package_file" "$sorted_package_file"

  package_count="$(line_count "$sorted_package_file")"
  write_summary_comment "$sorted_package_file" "$package_count" "$package_limit"
  publish_script_result
}

temp_files=()
main "$@"
