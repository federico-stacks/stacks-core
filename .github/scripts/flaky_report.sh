#!/usr/bin/env bash
#
# Reports the outcome of every test in a nightly flakiness run.
#
# Reads the nextest JUnit reports produced by the test jobs and records what
# happened to each test that ran. The nightly runs the `flaky-scan` profile with
# `retries = 0`, so every failure here is a single-attempt failure against the
# default branch - a flake candidate, not a retry artifact and not caused by a
# pull request's changes.
#
# Required env vars:
#   JUNIT_DIR           - Directory holding the downloaded junit_*.xml reports
#
# Optional env vars:
#   OBSERVED_TESTS_FILE - JSONL, one object per test that ran, sorted by name:
#                           {"name": ..., "status": "pass"|"fail",
#                            "time": <seconds>, "excerpt": ...}
#                         `excerpt` is empty for passing tests. Skipped tests are
#                         omitted: they never reached a verdict.
#                         (default: observed-tests.jsonl)
#
# Outputs:
#   - the file above, read by the issue steps in this same job
#   - a markdown summary appended to $GITHUB_STEP_SUMMARY when set
#
# Not in scope: classifying failures by mode, normalising failure signatures,
# tracking history across runs, and filing issues. Those are separate steps so
# each can be reviewed on its own.
#
# Exit behaviour:
#   Always exits 0 when the reports were readable. Test failures are reported by
#   the test jobs themselves; failing here would only hide the summary.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

## Load logging functions
# shellcheck disable=SC1091
source "${script_dir}/logging.sh"

## --- Configuration ----------------------------------------------------------
junit_dir="${JUNIT_DIR:-}"
observed_tests_file="${OBSERVED_TESTS_FILE:-observed-tests.jsonl}"

# Enough of the output to recognise the failure, without pasting a whole
# backtrace into an issue body later. Read by excerpt() below.
excerpt_lines=10

## ── Check for required binaries ─────────────────────────────────────────────
missing=0
for cmd in awk find grep jq sort xmllint; do
    if ! command -v "${cmd}" > /dev/null 2>&1; then
        error "Missing required command: $(hl "${cmd}")"
        missing=1
    fi
done
if [[ "${missing}" -eq 1 ]]; then
    error "xmllint comes from the $(hl "libxml2-utils") package"
    exit 1
fi

## ── Validate required inputs ────────────────────────────────────────────────
if [[ -z "${junit_dir}" ]]; then
    error "JUNIT_DIR is not set"
    exit 1
fi

## ── Main ────────────────────────────────────────────────────────────────────
main() {
    local -a reports
    local report_count report observed_count failed_count
    local failed_names skipped_names name status duration failure_text excerpt_text record

    ## Collect the reports
    mapfile -t reports < <(find "${junit_dir}" -type f -name '*.xml' 2> /dev/null | sort)
    report_count="${#reports[@]}"

    : > "${observed_tests_file}"

    # A run that produced no reports failed before the tests executed. That is a
    # very different thing from "no test failed", so never let it read as success.
    if [[ "${report_count}" -eq 0 ]]; then
        warn "No JUnit reports found under $(hl "${junit_dir}")"
        summary "## Nightly flakiness run"
        summary ""
        summary "**No test results were parsed.** The run failed before the tests"
        summary "executed - check the archive and test jobs. This is not the same as"
        summary "a run in which no test failed."
        summary ""
        return 0
    fi

    info "Parsing $(hl "${report_count}") JUnit report(s) from $(hl "${junit_dir}")..."

    ## Record every test that ran
    for report in "${reports[@]}"; do
        # Categorise once per report rather than querying per test
        failed_names=$(test_names "${report}" '//testcase[failure or error]/@name')
        skipped_names=$(test_names "${report}" '//testcase[skipped]/@name')

        while read -r name; do
            [[ -z "${name}" ]] && continue

            # A skipped test never reached a verdict, so it is not "observed".
            # nextest does not currently emit these - the "N skipped" in its
            # terminal output is filter-excluded tests, which never appear in the
            # report at all - but exclude them in case that changes.
            if grep -qxF "${name}" <<< "${skipped_names}"; then
                continue
            fi

            # Fetch values by name rather than by position, so they cannot be
            # mismatched across separate queries. Rust test names contain no
            # quotes, so embedding one in the XPath is safe.
            duration=$(xpath "string(//testcase[@name='${name}']/@time)" "${report}" \
                | awk '{printf "%.0f", $1}')

            if grep -qxF "${name}" <<< "${failed_names}"; then
                status="fail"
                # string() gives the element's decoded string value. text() would
                # return a node-set that xmllint re-serializes, leaving &lt; and
                # friends escaped in the output.
                failure_text=$(xpath "string(//testcase[@name='${name}']/*[self::failure or self::error])" "${report}")

                # nextest repeats the first line of the body in @message, so prefer
                # the body and fall back to @message only when the body is empty -
                # which is what happens when the test process aborts.
                if [[ -z "${failure_text//[[:space:]]/}" ]]; then
                    failure_text=$(xpath "string(//testcase[@name='${name}']/*[self::failure or self::error]/@message)" "${report}")
                fi
                excerpt_text="$(excerpt "${failure_text}")"
            else
                status="pass"
                excerpt_text=""
            fi

            jq -nc \
                --arg name "${name}" \
                --arg status "${status}" \
                --arg excerpt "${excerpt_text}" \
                --argjson time "${duration:-0}" \
                '{name: $name, status: $status, time: $time, excerpt: $excerpt}' \
                >> "${observed_tests_file}"
        done < <(test_names "${report}" '//testcase/@name')
    done

    # Sorted by test name: stable between runs, so two runs' outputs diff cleanly,
    # and tests from the same module group together - three failures under one
    # module often share a single root cause.
    if [[ -s "${observed_tests_file}" ]]; then
        jq -s -c 'sort_by(.name)[]' "${observed_tests_file}" > "${observed_tests_file}.sorted"
        mv "${observed_tests_file}.sorted" "${observed_tests_file}"
    fi

    observed_count=$(grep -c '' "${observed_tests_file}" || true)
    failed_count=$(jq -s '[.[] | select(.status == "fail")] | length' "${observed_tests_file}")

    ## Report
    summary "## Nightly flakiness run"
    summary ""
    summary "| | |"
    summary "| --- | --- |"
    summary "| JUnit reports parsed | ${report_count} |"
    summary "| Tests observed | ${observed_count} |"
    summary "| Failed | ${failed_count} |"
    summary ""

    if [[ "${failed_count}" -eq 0 ]]; then
        summary "No failures. Every test passed on a single attempt."
        summary ""
    else
        summary "### Failed tests"
        summary ""
        summary "| Test | Duration |"
        summary "| --- | --- |"
        # jq joins the fields with tabs and `read` splits them apart again. This
        # is safe because @tsv escapes any tab, newline, CR or backslash *inside*
        # a value as a two-character sequence, so a record is always one line
        # carrying exactly the field count jq emitted - no value can mis-split
        # the row. The trade-off is that a multi-line value would arrive with a
        # literal `\n` in it, so records holding one are read as JSON instead
        # (see the raw-results block below).
        while IFS=$'\t' read -r name duration; do
            summary "| \`${name}\` | ${duration}s |"
        done < <(jq -r 'select(.status == "fail") | [.name, .time] | @tsv' "${observed_tests_file}")
        summary ""
        summary "Retries are disabled on this profile, so each of these failed on a"
        summary "single attempt against the default branch."
        summary ""

        # The failing records, collapsed so they do not dominate the summary.
        # Filtered to failures: printing every observed test would be hundreds of
        # lines on a full-width run.
        summary "<details>"
        summary "<summary>Raw results for failures (<code>${observed_tests_file}</code>)</summary>"
        summary ""
        summary '```json'
        while IFS= read -r record; do
            summary "${record}"
        done < <(jq -c 'select(.status == "fail")' "${observed_tests_file}")
        summary '```'
        summary ""
        summary "</details>"
        summary ""
    fi

    info "Wrote $(hl "${observed_count}") observed test(s), $(hl "${failed_count}") failing, to $(hl "${observed_tests_file}")"
}

## ── Helpers ─────────────────────────────────────────────────────────────────
#
# Defined after main() on purpose: bash resolves function names when they are
# called, not when the file is parsed, so main() can read top-down while the
# helpers it uses sit out of the way below.

# Run an XPath query, treating "no match" as empty rather than an error.
# xmllint exits non-zero and prints "XPath set is empty" when nothing matches.
xpath() {
    local expression="$1" file="$2"
    xmllint --xpath "${expression}" "${file}" 2> /dev/null || true
}

# Test names from an XPath selecting @name attributes. Querying attributes
# returns ` name="..."` pairs, so pull the values back out.
test_names() {
    local file="$1" expression="$2"
    xpath "${expression}" "${file}" \
        | grep -o 'name="[^"]*"' \
        | sed 's/^name="//; s/"$//' || true
}

# The part of the captured output that says why the test failed. Prefers the
# panic line and what follows; otherwise keeps the tail, which is where nextest
# prints the reason. No interpretation of the content - identifying the *kind*
# of failure is a later step.
excerpt() {
    local text="$1"

    # An empty failure element carries no diagnostic at all: nextest emits
    # a bare <failure type="test failure"/> in some versions when output
    # storage is disabled. Handle it explicitly - otherwise the greps below
    # match nothing, exit 1, and pipefail plus set -e abort the whole script,
    # losing the entire report.
    if [[ -z "${text//[[:space:]]/}" ]]; then
        printf '%s' '(no failure detail in the JUnit report; see the job log)'
        return 0
    fi

    if grep -qi 'panicked at' <<< "${text}"; then
        grep -i -A"$(( excerpt_lines - 1 ))" 'panicked at' <<< "${text}" \
            | sed '/[Ss]tack backtrace:/Q' \
            | head -n "${excerpt_lines}"
    else
        grep -v '^[[:space:]]*$' <<< "${text}" | tail -n 15
    # A trailing `|| true` because this helper is best-effort by design: no
    # shape of failure output should be able to fail the run.
    fi | sed 's/[[:space:]]*$//' || true
}

# Append a line to the job summary, and echo it so the log shows the report
# too. printf rather than echo: the raw results block above contains JSON with
# backslash escapes, which some echo implementations would interpret.
summary() {
    printf '%s\n' "$*"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        printf '%s\n' "$*" >> "${GITHUB_STEP_SUMMARY}"
    fi
}

## ── Entry point ─────────────────────────────────────────────────────────────
# Guarded so a test harness can source this file and exercise the helpers above
# in isolation without running the whole report.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
