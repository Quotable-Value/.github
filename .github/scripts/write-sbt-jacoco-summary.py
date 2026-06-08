#!/usr/bin/env python3
import os
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def int_attr(element, name):
    try:
        return int(element.get(name, "0"))
    except ValueError:
        return 0


def counter(element, counter_type):
    for item in element.findall("counter"):
        if item.get("type") == counter_type:
            return int_attr(item, "covered"), int_attr(item, "missed")
    return 0, 0


def percent(covered, missed):
    total = covered + missed
    if total == 0:
        return "n/a"
    return f"{covered * 100 / total:.2f}%"


def markdown_escape(value):
    return str(value).replace("|", "\\|").replace("\n", " ")


def row(metric, covered, missed):
    total = covered + missed
    return f"| {metric} | {covered} | {missed} | {total} | {percent(covered, missed)} |"


def read_package_limit():
    try:
        package_limit = int(os.environ.get("JACOCO_PACKAGE_ROW_LIMIT", "20"))
    except ValueError:
        package_limit = 20
    return max(package_limit, 0)


def write_empty_comment(comment_file):
    comment_file.parent.mkdir(parents=True, exist_ok=True)
    comment_file.write_text("", encoding="utf-8")


def main():
    comment_file = Path(os.environ["COMMENT_FILE"])
    xml_file = Path(os.environ["JACOCO_REPORT_DIRECTORY"]) / "jacoco.xml"

    if not xml_file.is_file():
        write_empty_comment(comment_file)
        return 0

    try:
        root = ET.parse(xml_file).getroot()
    except ET.ParseError:
        write_empty_comment(comment_file)
        return 0

    metrics = [
        ("Lines", "LINE"),
        ("Branches", "BRANCH"),
        ("Methods", "METHOD"),
        ("Instructions", "INSTRUCTION"),
    ]
    total_rows = [row(label, *counter(root, counter_type)) for label, counter_type in metrics]

    packages = []
    for package in root.findall("package"):
        name = package.get("name", "").replace("/", ".") or "(default)"
        line_covered, line_missed = counter(package, "LINE")
        branch_covered, branch_missed = counter(package, "BRANCH")
        method_covered, method_missed = counter(package, "METHOD")
        if line_covered + line_missed + branch_covered + branch_missed + method_covered + method_missed == 0:
            continue
        packages.append({
            "name": name,
            "line_missed": line_missed,
            "lines": percent(line_covered, line_missed),
            "branches": percent(branch_covered, branch_missed),
            "methods": percent(method_covered, method_missed),
        })

    package_limit = read_package_limit()
    packages.sort(key=lambda item: (-item["line_missed"], item["name"]))
    visible_packages = packages[:package_limit] if package_limit else []

    artifact_url = os.environ.get("ARTIFACT_URL", "")
    artifact_line = "- HTML report: not uploaded"
    if artifact_url:
        artifact_line = f"- HTML report: [workflow artifact]({artifact_url})"

    lines = [
        "### SBT Jacoco coverage",
        "",
        f"- Working directory: `{os.environ.get('WORKING_DIRECTORY', '.')}`",
        f"- Command: `{os.environ.get('COVERAGE_COMMAND', '')}`",
        f"- Result: `{os.environ.get('COVERAGE_RESULT', 'skipped')}`",
        artifact_line,
        "",
        "#### Totals",
        "",
        "| Metric | Covered | Missed | Total | Coverage |",
        "| --- | ---: | ---: | ---: | ---: |",
        *total_rows,
    ]

    if visible_packages:
        lines.extend([
            "",
            "#### Packages",
            "",
            "| Package | Lines | Branches | Methods |",
            "| --- | ---: | ---: | ---: |",
        ])
        for package in visible_packages:
            lines.append(
                f"| {markdown_escape(package['name'])} | {package['lines']} | {package['branches']} | {package['methods']} |"
            )
        if len(packages) > len(visible_packages):
            lines.append("")
            lines.append(f"Showing {len(visible_packages)} of {len(packages)} packages, sorted by missed lines.")

    comment_file.parent.mkdir(parents=True, exist_ok=True)
    comment_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())
