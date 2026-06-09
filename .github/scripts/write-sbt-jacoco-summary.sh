#!/usr/bin/env bash
set -euo pipefail

: "${COMMENT_FILE:?COMMENT_FILE is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY is required}"
: "${JACOCO_REPORT_DIRECTORY:?JACOCO_REPORT_DIRECTORY is required}"

echo "comment_file=$COMMENT_FILE" >> "$GITHUB_OUTPUT"

xml_file="${JACOCO_REPORT_DIRECTORY%/}/jacoco.xml"

write_empty_comment() {
  mkdir -p "$(dirname "$COMMENT_FILE")"
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

package_limit="${JACOCO_PACKAGE_ROW_LIMIT:-20}"
if ! [[ "$package_limit" =~ ^[0-9]+$ ]]; then
  package_limit=20
fi

if [ ! -f "$xml_file" ] || ! grep -q '<report' "$xml_file"; then
  write_empty_comment
else
  parsed_file="$(mktemp)"
  package_file="$(mktemp)"
  sorted_package_file="$(mktemp)"
  trap 'rm -f "$parsed_file" "$package_file" "$sorted_package_file"' EXIT

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

  line_covered=0
  line_missed=0
  branch_covered=0
  branch_missed=0
  method_covered=0
  method_missed=0
  instruction_covered=0
  instruction_missed=0

  while IFS=$'\t' read -r record_type first second third fourth fifth; do
    if [ "$record_type" = "T" ]; then
      case "$first" in
        LINE)
          line_covered="$second"
          line_missed="$third"
          ;;
        BRANCH)
          branch_covered="$second"
          branch_missed="$third"
          ;;
        METHOD)
          method_covered="$second"
          method_missed="$third"
          ;;
        INSTRUCTION)
          instruction_covered="$second"
          instruction_missed="$third"
          ;;
      esac
    elif [ "$record_type" = "P" ]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$first" "$second" "$third" "$fourth" "$fifth" >> "$package_file"
    fi
  done < "$parsed_file"

  LC_ALL=C sort -t $'\t' -k1,1nr -k2,2 "$package_file" > "$sorted_package_file"
  package_count=$(wc -l < "$sorted_package_file" | tr -d ' ')

  artifact_line='- HTML report: not uploaded'
  if [ -n "${ARTIFACT_URL:-}" ]; then
    artifact_line="- HTML report: [workflow artifact](${ARTIFACT_URL})"
  fi

  mkdir -p "$(dirname "$COMMENT_FILE")"
  {
    echo '### SBT Jacoco coverage'
    echo ''
    echo "- Working directory: \`${WORKING_DIRECTORY:-.}\`"
    echo "- Command: \`${COVERAGE_COMMAND:-}\`"
    echo "- Result: \`${COVERAGE_RESULT:-skipped}\`"
    echo "$artifact_line"
    echo ''
    echo '#### Totals'
    echo ''
    echo '| Metric | Covered | Missed | Total | Coverage |'
    echo '| --- | ---: | ---: | ---: | ---: |'
    metric_row 'Lines' "$line_covered" "$line_missed"
    metric_row 'Branches' "$branch_covered" "$branch_missed"
    metric_row 'Methods' "$method_covered" "$method_missed"
    metric_row 'Instructions' "$instruction_covered" "$instruction_missed"

    if [ "$package_count" -gt 0 ] && [ "$package_limit" -gt 0 ]; then
      echo ''
      echo '#### Packages'
      echo ''
      echo '| Package | Lines | Branches | Methods |'
      echo '| --- | ---: | ---: | ---: |'

      visible_count=0
      while IFS=$'\t' read -r missed_lines package_name lines_pct branches_pct methods_pct; do
        if [ "$visible_count" -ge "$package_limit" ]; then
          break
        fi
        printf '| %s | %s | %s | %s |\n' "$(markdown_escape "$package_name")" "$lines_pct" "$branches_pct" "$methods_pct"
        visible_count=$((visible_count + 1))
      done < "$sorted_package_file"

      if [ "$package_count" -gt "$visible_count" ]; then
        echo ''
        echo "Showing $visible_count of $package_count packages, sorted by missed lines."
      fi
    fi
  } > "$COMMENT_FILE"
fi

if [ -s "$COMMENT_FILE" ]; then
  cat "$COMMENT_FILE" >> "$GITHUB_STEP_SUMMARY"
  echo "has_structured_summary=true" >> "$GITHUB_OUTPUT"
else
  echo "No Jacoco XML report was found." >> "$GITHUB_STEP_SUMMARY"
  echo "has_structured_summary=false" >> "$GITHUB_OUTPUT"
fi
