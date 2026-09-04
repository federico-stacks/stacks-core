#!/usr/bin/env bash
#
# Reports which tests failed in a nightly flakiness run.
#
# Reads the nextest JUnit reports produced by the test jobs and answers one
# question: which tests failed? The nightly runs the `ci-nightly` profile with
# `retries = 0`, so every failure here is a single-attempt failure against the
# default branch - a flake candidate, not a retry artifact and not caused by a
# pull request's changes.
#
# Required env vars:
#   JUNIT_DIR         - Directory holding the downloaded junit_*.xml reports
#
# Optional env vars:
#   FAILED_TESTS_FILE - JSONL, one object per failed test, sorted by name:
#                         {"name": ..., "time": <seconds>, "excerpt": ...}
#                       (default: failed-tests.jsonl)
#
# Outputs:
#   - the file above, read by the issue-filing step in this same job
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
failed_tests_file="${FAILED_TESTS_FILE:-failed-tests.jsonl}"

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
    local report_count report total_cases skipped_cases observed_cases failed_count
    local cases skipped name duration failure_text excerpt_text record

    ## Collect the reports
    mapfile -t reports < <(find "${junit_dir}" -type f -name '*.xml' 2> /dev/null | sort)
    report_count="${#reports[@]}"

    : > "${failed_tests_file}"

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

    ## Extract counts and failures
    total_cases=0
    skipped_cases=0

    for report in "${reports[@]}"; do
        # xmllint prints counts as numbers; normalize to plain integers
        cases=$(xpath 'count(//testcase)' "${report}" | awk '{printf "%d", $1}')
        skipped=$(xpath 'count(//testcase/skipped)' "${report}" | awk '{printf "%d", $1}')
        total_cases=$(( total_cases + ${cases:-0} ))
        skipped_cases=$(( skipped_cases + ${skipped:-0} ))

        # Failed test names. Querying attributes returns ` name="..."` pairs, so
        # pull the values back out.
        while read -r name; do
            [[ -z "${name}" ]] && continue

            # Fetch this test's duration and output by name rather than by position,
            # so the values cannot be mismatched across separate queries. Rust test
            # names contain no quotes, so embedding one in the XPath is safe.
            duration=$(xpath "string(//testcase[@name='${name}']/@time)" "${report}" \
                | awk '{printf "%.0f", $1}')
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

            jq -nc \
                --arg name "${name}" \
                --arg excerpt "${excerpt_text}" \
                --argjson time "${duration:-0}" \
                '{name: $name, time: $time, excerpt: $excerpt}' \
                >> "${failed_tests_file}"
        done < <(xpath '//testcase[failure or error]/@name' "${report}" \
            | grep -o 'name="[^"]*"' \
            | sed 's/^name="//; s/"$//' || true)
    done

    observed_cases=$(( total_cases - skipped_cases ))

    # Sorted by test name: stable between runs, so two runs' outputs diff cleanly,
    # and tests from the same module group together - three failures under one
    # module often share a single root cause.
    if [[ -s "${failed_tests_file}" ]]; then
        jq -s -c 'sort_by(.name)[]' "${failed_tests_file}" > "${failed_tests_file}.sorted"
        mv "${failed_tests_file}.sorted" "${failed_tests_file}"
    fi
    failed_count=$(grep -c '' "${failed_tests_file}" || true)

    ## Report
    summary "## Nightly flakiness run"
    summary ""
    summary "| | |"
    summary "| --- | --- |"
    summary "| JUnit reports parsed | ${report_count} |"
    summary "| Tests observed | ${observed_cases} |"
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
        while IFS=$'\t' read -r name duration; do
            summary "| \`${name}\` | ${duration}s |"
        done < <(jq -r '[.name, .time] | @tsv' "${failed_tests_file}")
        summary ""
        summary "Retries are disabled on this profile, so each of these failed on a"
        summary "single attempt against the default branch."
        summary ""

        # The full records, collapsed so they do not dominate the summary. Useful
        # when the table alone does not explain a failure, and the only other
        # copy of this data is the job log.
        summary "<details>"
        summary "<summary>Raw results (<code>${failed_tests_file}</code>)</summary>"
        summary ""
        summary '```json'
        while IFS= read -r record; do
            summary "${record}"
        done < "${failed_tests_file}"
        summary '```'
        summary ""
        summary "</details>"
        summary ""
    fi

    info "Wrote $(hl "${failed_count}") failure(s) to $(hl "${failed_tests_file}")"
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
