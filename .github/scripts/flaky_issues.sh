#!/usr/bin/env bash
#
# Keeps one GitHub issue per flaky test in step with the workflow's results.
#
# Two phases, both driven by observed-tests.jsonl from flaky_report.sh:
#
#   1. Tests that FAILED    -> file a new issue, or comment on the existing one
#   2. Tests that PASSED    -> close the issue once the test has been quiet for
#                              QUIET_AFTER qualifying workflow runs
#   2b. Tests never SEEN    -> close the issue once the test has gone unobserved
#                              for ORPHAN_AFTER runs (renamed, deleted, excluded)
#
# A run that failed MASS_FAILURE_THRESHOLD or more tests is treated as broken
# rather than flaky: none of the three phases runs, because the results are not
# trustworthy evidence about any individual test - see the guard in main().
#
# A test absent from one run is left alone: it may simply not have run (a
# narrowed `only-tests` matrix, an excluded test, or a job that never reported).
# One run's absence says nothing, but absence that persists says plenty, so an
# issue closes once its test has gone unobserved for ORPHAN_AFTER runs. That
# needs no judgement about *why* it vanished, which is the point: renamed,
# deleted and excluded are indistinguishable from the results alone.
#
# One issue per test, so the issue becomes that test's record: every workflow
# run in which it fails appends a comment. Evidence is written as text rather than
# only as a link, because Actions job logs are deleted after the retention period 
# while the issue is permanent.
#
# Required env vars:
#   GH_TOKEN            - token with issues:write on GITHUB_REPOSITORY
#   GITHUB_REPOSITORY   - owner/repo to file issues against
#   GITHUB_WORKFLOW     - this workflow's name, supplied by Actions. Used to
#                         count its own run history, so the count follows the
#                         workflow it is running in and cannot drift out of
#                         sync with a hardcoded name
#   MAX_NEW_ISSUES      - cap on issues CREATED in one run. Commenting on issues
#                         that already exist is never capped. Anything deferred
#                         is named in the job summary, never dropped silently
#   QUIET_AFTER         - how many quiet runs before an issue is closed.
#                         0 closes as soon as the test passes
#   QUIET_RUN_EVENTS    - comma-separated workflow event names that count as a
#                         chance for the test to fail; surrounding whitespace is
#                         trimmed, so "schedule, workflow_dispatch" works.
#                         Scheduled runs are always full-width, which is what
#                         makes them a fair measure; `workflow_dispatch` can be
#                         added to exercise the threshold without waiting for
#                         the cron
#   ORPHAN_AFTER        - how many runs a test may go *unobserved* before its
#                         issue is closed as no longer watched. Must be greater
#                         than QUIET_AFTER - see close_quiet_issues()
#   MASS_FAILURE_THRESHOLD
#                       - failures at or above which the run is treated as
#                         broken and no issue is touched at all.
#   DRY_RUN             - "true" to print every mutation instead of performing it
#   FLAKY_LABEL         - the label every issue carries.
#   OBSERVED_TESTS_FILE - JSONL written by flaky_report.sh earlier in the same
#                         job.
#
# Exit behavior:
#   Exits 0 when triage completed, whether or not any test failed.
#
#   Exits 1 when triage was REFUSED: no results were observed, or the run failed
#   so many tests that it cannot be trusted. Both cases mean no issue was filed,
#   commented on or closed.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${script_dir}/logging.sh"

# Script entry point
main() {
    initialize

    local existing_issues observed_count failed_count
    local created=0 updated=0 reopened=0 closed=0 orphaned=0
    local run_looks_broken="false"
    local -a deferred=()
    
    # Precondition: this run must have observed something
    if [[ ! -s "${CFG_OBSERVED_TESTS_FILE}" ]]; then
        warn "No tests were observed in this run - nothing to do"
        summary "## Flaky test issues"
        summary ""
        summary "**No test results were observed**, so no issue was filed, updated or closed."
        summary "This is not the same as a run in which no test failed - check the archive"
        summary "and test jobs."
        summary ""
        return 1
    fi

    observed_count=$(grep -c '' "${CFG_OBSERVED_TESTS_FILE}" || true)
    failed_count=$(jq -s '[.[] | select(.status == "fail")] | length' "${CFG_OBSERVED_TESTS_FILE}")
    info "Observed $(hl "${observed_count}") test(s), $(hl "${failed_count}") failing, on $(hl "${CFG_REPO}")"

    # Mass-failure guard: is this a flaky run, or a broken one?
    if (( failed_count >= CFG_MASS_FAILURE_THRESHOLD )); then
        run_looks_broken="true"
        warn "$(hl "${failed_count}") failures at or above $(hl "MASS_FAILURE_THRESHOLD")=$(hl "${CFG_MASS_FAILURE_THRESHOLD}")"
        warn "Treating this run as broken: nothing will be filed, commented on, or closed"
        report_summary
        return 1
    fi

    # Manage Github issue lifecycle
    existing_issues="$(mktemp)"
    load_existing_issues "${existing_issues}"
    ## Phase 1: create, update, or reopen issues for tests that failed in this run
    file_failure_issues "${existing_issues}"
    ## Phase 2: close issues for tests that have gone quiet or orphaned
    close_quiet_issues "${existing_issues}"
    rm -f "${existing_issues}"

    report_summary
}

## ── Helpers ─────────────────────────────────────────────────────────────────

# Initialize the script, checking preconditions and loading configuration. 
# Exits on failure.
initialize() {
    # Preconditions: tools
    local missing_cmds=() cmd
    for cmd in gh jq; do
        command -v "${cmd}" > /dev/null 2>&1 || missing_cmds+=("${cmd}")
    done
    if (( ${#missing_cmds[@]} > 0 )); then
        error "Missing required command(s): $(hl "${missing_cmds[*]}")"
        exit 1
    fi

    # Preconditions: inputs
    require_vars "Github env" \
        GH_TOKEN \
        GITHUB_REPOSITORY \
        GITHUB_WORKFLOW

    require_vars "Custom input" \
        OBSERVED_TESTS_FILE \
        FLAKY_LABEL \
        MAX_NEW_ISSUES \
        QUIET_AFTER \
        QUIET_RUN_EVENTS \
        ORPHAN_AFTER \
        MASS_FAILURE_THRESHOLD \
        DRY_RUN

    # Configuration
    CFG_WORKFLOW_NAME="${GITHUB_WORKFLOW}"
    CFG_REPO="${GITHUB_REPOSITORY}"
    CFG_OBSERVED_TESTS_FILE="${OBSERVED_TESTS_FILE}"
    CFG_FLAKY_LABEL="${FLAKY_LABEL}"
    CFG_MAX_NEW_ISSUES="${MAX_NEW_ISSUES}"
    CFG_QUIET_AFTER="${QUIET_AFTER}"
    CFG_QUIET_RUN_EVENTS="${QUIET_RUN_EVENTS}"
    CFG_ORPHAN_AFTER="${ORPHAN_AFTER}"
    CFG_MASS_FAILURE_THRESHOLD="${MASS_FAILURE_THRESHOLD}"
    CFG_DRY_RUN="${DRY_RUN}"
    
    # Marker carrying the fully qualified test name within a Github issue
    CFG_ID_MARKER_PREFIX="test-id"

    # Starts every evidence comment, and is how the close phase dates the last
    # failure - the writer and the reader must stay in step.
    CFG_FAILURE_HEADING="### Failure - "

    # Applied only when creating the label; matches the upstream `flaky` label.
    CFG_FLAKY_LABEL_COLOR="58BCF1"

    # Long enough that captured output containing triple backticks cannot break out
    CFG_FENCE='`````'

    # Display only, so a missing GITHUB_* degrades the link, not the run.
    CFG_RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${CFG_REPO}/actions/runs/${GITHUB_RUN_ID:-}"
    CFG_TODAY="$(date -u +%Y-%m-%d)"

    # Validate the configuration
    if (( CFG_ORPHAN_AFTER <= CFG_QUIET_AFTER )); then
        error "$(hl "ORPHAN_AFTER") (${CFG_ORPHAN_AFTER}) must be greater than $(hl "QUIET_AFTER") (${CFG_QUIET_AFTER})"
        error "Otherwise one unreported test job could close the issue of a passing test."
        exit 1
    fi

    info "Config: quiet-after=$(hl "${CFG_QUIET_AFTER}") orphan-after=$(hl "${CFG_ORPHAN_AFTER}") mass-failure=$(hl "${CFG_MASS_FAILURE_THRESHOLD}") max-new=$(hl "${CFG_MAX_NEW_ISSUES}") events=$(hl "${CFG_QUIET_RUN_EVENTS}") dry-run=$(hl "${CFG_DRY_RUN}")"
    
    # Preconditions: Github issues must be enabled
    if [[ "$(gh api "repos/${CFG_REPO}" --jq '.has_issues')" != "true" ]]; then
        error "Issues are disabled on $(hl "${CFG_REPO}"), so no issue can be filed!"
        exit 1
    fi

    # Preconditions: Github lable must exists
    ensure_flaky_label
}

# Create the label if the repo does not have it yet.
ensure_flaky_label() {
    local existing_labels

    # Not piped into grep -q: that exits on first match and can SIGPIPE gh,
    # which under pipefail reads as "label missing" and re-creates it.
    existing_labels=$(gh label list --repo "${CFG_REPO}" --limit 200 --json name --jq '.[].name')

    if grep -qxF "${CFG_FLAKY_LABEL}" <<< "${existing_labels}"; then
        info "Label already exists: $(hl "${CFG_FLAKY_LABEL}")"
    else
        info "Creating label: $(hl "${CFG_FLAKY_LABEL}")"
        gh_mutate label create "${CFG_FLAKY_LABEL}" --repo "${CFG_REPO}" \
            --color "${CFG_FLAKY_LABEL_COLOR}" \
            --description "Test that fails intermittently in CI"
    fi
}

# Write every issue we have already filed to the given file. `comments` is
# needed because the close phase dates each issue's last failure from them.
load_existing_issues() {
    local target="$1"

    gh issue list --repo "${CFG_REPO}" --label "${CFG_FLAKY_LABEL}" --state all \
        --limit 500 --json number,state,body,comments > "${target}"

    info "Found $(hl "$(jq 'length' "${target}")") existing $(hl "${CFG_FLAKY_LABEL}") issue(s)"
}

# Create, update, or reopen issues for tests that failed in this run
file_failure_issues() {
    local existing_issues="$1"
    local record name duration excerpt marker comment_file body_file
    local match number state url

    while IFS= read -r record; do
        name=$(jq -r '.name' <<< "${record}")
        duration=$(jq -r '.time' <<< "${record}")
        excerpt=$(jq -r '.excerpt' <<< "${record}")
        [[ -z "${name}" ]] && continue

        marker="<!-- ${CFG_ID_MARKER_PREFIX}: ${name} -->"

        # The evidence comment, identical whether the issue is new or existing
        comment_file="$(mktemp)"
        {
            echo "${CFG_FAILURE_HEADING}${CFG_TODAY}"
            echo
            echo "- **Run:** [${GITHUB_RUN_ID:-unknown}](${CFG_RUN_URL})"
            echo "- **Commit:** \`${GITHUB_SHA:-unknown}\` on \`${GITHUB_REF_NAME:-unknown}\`"
            echo "- **Duration:** ${duration}s"
            echo
            echo "${CFG_FENCE}text"
            printf '%s\n' "${excerpt}"
            echo "${CFG_FENCE}"
            echo
            echo "Full test output is in the run's job log, which is subject to GitHub retention policy."
        } > "${comment_file}"

        # Exact-match the marker against the bodies we already have. No match
        # leaves both fields empty. @tsv escapes any tab or newline *inside* a
        # value, so the row can never mis-split - which is why multi-line values
        # like the excerpt above travel as JSON instead.
        #
        # Assigned first, then read: `read <<< "$(jq ...)"` reports read's
        # status rather than jq's, so a jq failure would look like "no match"
        # and file a duplicate issue. As an assignment it aborts under set -e.
        match=$(jq -r --arg marker "${marker}" '
            map(select(.body != null and (.body | contains($marker))))
            | if length == 0 then "" else [.[0].number, .[0].state] | @tsv end
        ' "${existing_issues}")
        IFS=$'\t' read -r number state <<< "${match}"

        if [[ -z "${number}" ]]; then
            if (( created >= CFG_MAX_NEW_ISSUES )); then
                deferred+=("${name}")
                rm -f "${comment_file}"
                continue
            fi

            body_file="$(mktemp)"
            {
                echo "The following test looks flaky: \`${name}\`."
                echo
                echo "**Triage**"
                echo
                echo "- [ ] Reproduced"
                echo "- [ ] Classified: test bug or production bug"
                echo "- [ ] Root cause identified"
                echo
                echo "> Filed automatically by \`${CFG_WORKFLOW_NAME}\`."
                echo
                echo "${marker}"
            } > "${body_file}"

            info "Creating issue for $(hl "${name}")"
            url=$(gh_mutate issue create --repo "${CFG_REPO}" \
                --title "[Flaky Test] ${name}" \
                --label "${CFG_FLAKY_LABEL}" \
                --body-file "${body_file}" || true)
            rm -f "${body_file}"

            # Post the first evidence as a comment too, so a new issue and an old
            # one carry the same shape of history
            if [[ -n "${url}" ]]; then
                number="${url##*/}"
                gh_mutate issue comment "${number}" --repo "${CFG_REPO}" \
                    --body-file "${comment_file}"
            elif [[ "${CFG_DRY_RUN}" == "true" ]]; then
                info "DRY-RUN: gh issue comment <new issue> --repo ${CFG_REPO} --body-file <evidence>"
            fi
            created=$(( created + 1 ))
        else
            if [[ "${state}" == "CLOSED" ]]; then
                info "Reopening #${number} for $(hl "${name}")"
                gh_mutate issue reopen "${number}" --repo "${CFG_REPO}"
                reopened=$(( reopened + 1 ))
            fi

            info "Adding evidence to #${number} for $(hl "${name}")"
            gh_mutate issue comment "${number}" --repo "${CFG_REPO}" \
                --body-file "${comment_file}"
            updated=$(( updated + 1 ))
        fi

        rm -f "${comment_file}"
    done < <(jq -c 'select(.status == "fail")' "${CFG_OBSERVED_TESTS_FILE}")
}

## Close issues whose test has gone quiet by passing, or vanished entirely.
#
# Two closes sharing one counter - qualifying runs since the test last failed:
#
#   pass   + quiet_count >= QUIET_AFTER   -> "went quiet"  (positive evidence)
#   absent + quiet_count >= ORPHAN_AFTER  -> "not watched" (negative evidence)
close_quiet_issues() {
    local existing_issues="$1"
    local quiet_runs number state test_id test_status last_failure quiet_count
    local comment reason
    local -A observed_status=()

    # Status of every test that ran, so "passed" is distinguishable from "did
    # not run" - otherwise a narrowed `only-tests` run would close everything.
    while IFS=$'\t' read -r test_id test_status; do
        observed_status["${test_id}"]="${test_status}"
    done < <(jq -r '[.name, .status] | @tsv' "${CFG_OBSERVED_TESTS_FILE}")

    # Runs that gave every test a chance to fail. One call for the whole phase.
    # Event names are trimmed because QUIET_RUN_EVENTS is free-text: without it
    # "schedule, workflow_dispatch" silently drops the second name.
    quiet_runs=$(gh run list --repo "${CFG_REPO}" --workflow "${CFG_WORKFLOW_NAME}" \
        --limit 200 --json event,createdAt,conclusion \
        | jq -c --arg events "${CFG_QUIET_RUN_EVENTS}" '
            ($events
             | split(",")
             | map(gsub("^\\s+|\\s+$"; ""))
             | map(select(length > 0))) as $want
            | [ .[]
                | select((.event as $e | $want | index($e)) and .conclusion != "cancelled")
                | .createdAt ]')

    # Nothing can ever close at zero, and a typo in the event names is likelier
    # than a genuine absence.
    if [[ "$(jq 'length' <<< "${quiet_runs}")" -eq 0 ]]; then
        warn "No $(hl "${CFG_QUIET_RUN_EVENTS}") run(s) found - nothing can close as quiet"
    fi

    info "Counting quiet runs against $(hl "$(jq 'length' <<< "${quiet_runs}")") $(hl "${CFG_QUIET_RUN_EVENTS}") run(s)"

    while IFS=$'\t' read -r number state test_id last_failure; do
        [[ -z "${test_id}" ]] && continue

        # Only open issues can be closed
        [[ "${state}" != "OPEN" ]] && continue

        # Both branches need it. An issue with no failure comment counts as
        # infinitely quiet, since every run sorts after "no failure".
        quiet_count=$(jq --arg last "${last_failure}" \
            '[.[] | select($last == "" or . > $last)] | length' <<< "${quiet_runs}")

        case "${observed_status[${test_id}]:-absent}" in
            fail)
                # Phase 1 just recorded a failure; nothing to close
                continue
                ;;
            pass)
                (( quiet_count >= CFG_QUIET_AFTER )) || continue
                reason="quiet"
                ;;
            absent)
                (( quiet_count >= CFG_ORPHAN_AFTER )) || continue
                reason="orphan"
                ;;
            *)
                # Only pass/fail are ever written: the format changed.
                warn "Unknown status $(hl "${observed_status[${test_id}]}") for $(hl "${test_id}") - skipping"
                continue
                ;;
        esac

        if [[ "${reason}" == "quiet" ]]; then
            comment="$(quiet_comment "${quiet_count}" "${last_failure}")"
            info "Closing #${number} for $(hl "${test_id}") after $(hl "${quiet_count}") quiet run(s)"
            closed=$(( closed + 1 ))
        else
            comment="$(orphan_comment "${quiet_count}" "${last_failure}")"
            info "Closing #${number} for $(hl "${test_id}") - unobserved for $(hl "${quiet_count}") run(s)"
            orphaned=$(( orphaned + 1 ))
        fi

        gh_mutate issue close "${number}" --repo "${CFG_REPO}" --comment "${comment}"
    done < <(jq -r --arg prefix "${CFG_ID_MARKER_PREFIX}" --arg heading "${CFG_FAILURE_HEADING}" '
        .[]
        | select(.body != null)
        | . as $issue
        | ($issue.body | capture("<!--\\s*" + $prefix + ":\\s*(?<id>\\S+)\\s*-->")?) as $m
        | select($m != null)
        | [ $issue.number,
            $issue.state,
            $m.id,
            ([$issue.comments[]? | select(.body | startswith($heading)) | .createdAt] | max) // ""
          ]
        | @tsv
    ' "${existing_issues}")
}

# Quiet comment
quiet_comment() {
    local quiet_count="$1" last_failure="$2" comment

    comment="### Closed automatically - the test has gone quiet

The test passed in this run, and has not failed in the last ${quiet_count} run(s)."
    if [[ -n "${last_failure}" ]]; then
        comment="${comment}
Last recorded failure: ${last_failure%%T*}."
    fi

    printf '%s\n' "${comment}

**If the test fails again this issue reopens automatically** with the new failure attached."
}

# Orphaned comment: due to a tests being renamed, deleted or excluded.
orphan_comment() {
    local quiet_count="$1" last_failure="$2" comment

    comment="### Closed automatically - the test is no longer being watched

The test has not been observed in the last ${quiet_count} run(s). It may have been
renamed, deleted, or excluded from CI."
    if [[ -n "${last_failure}" ]]; then
        comment="${comment}
Last recorded failure: ${last_failure%%T*}."
    fi

    printf '%s\n' "${comment}

**If a test by this name fails again this issue reopens automatically** with the new failure attached."
}

# Exit unless every named variable is set and non-empty. Reports all the misses
# at once, since a broken env block tends to drop several. `provider` names who
# should have supplied them, which is what tells the reader where to look.
require_vars() {
    local provider="$1"
    shift
    local missing=() var

    for var in "$@"; do
        [[ -n "${!var:-}" ]] || missing+=("${var}")
    done

    if (( ${#missing[@]} > 0 )); then
        error "Not provided by ${provider}: $(hl "${missing[*]}")"
        exit 1
    fi
}

# Build the job summary from the counters main() and the phases maintained.
report_summary() {
    summary "## Flaky test issues"
    summary ""
    if [[ "${run_looks_broken}" == "true" ]]; then
        # Never let a suppressed run read as a quiet one
        summary "### This run looks broken, not flaky"
        summary ""
        summary "${failed_count} of ${observed_count} observed tests failed, at or above the"
        summary "\`MASS_FAILURE_THRESHOLD\` of ${CFG_MASS_FAILURE_THRESHOLD}. A failure count that high"
        summary "usually means the run itself broke - a cache miss, a toolchain break, a corrupt"
        summary "archive - rather than that ${failed_count} tests are independently flaky."
        summary ""
        summary "**No issue was filed, commented on, closed or reopened.**"
        summary "Recording these failures would reset every affected issue's last-failure date and"
        summary "delay its closure by the whole quiet window. The failing tests are listed in the"
        summary "report above, and in the run's JSONL artifact."
        summary ""
        summary "If the failures turn out to be unrelated to each other, this threshold is too low."
        summary ""
    fi
    if [[ "${CFG_DRY_RUN}" == "true" ]]; then
        summary "\`DRY_RUN\` was set: no issues were created, updated or closed."
        summary ""
    fi
    summary "| | |"
    summary "| --- | --- |"
    summary "| Tests observed | ${observed_count} |"
    summary "| Failing tests | ${failed_count} |"
    summary "| Issues created | ${created} |"
    summary "| Issues updated | ${updated} |"
    summary "| Issues reopened | ${reopened} |"
    summary "| Issues closed as quiet | ${closed} |"
    summary "| Issues closed as no longer watched | ${orphaned} |"
    summary ""

    if (( ${#deferred[@]} > 0 )); then
        # Never let a cap look like clean results
        summary "### Deferred to the next run"
        summary ""
        summary "The \`MAX_NEW_ISSUES\` cap of ${CFG_MAX_NEW_ISSUES} was reached, so no issue was"
        summary "filed for these failing tests. They will be filed on a later run."
        summary ""
        for name in "${deferred[@]}"; do
            summary "- \`${name}\`"
        done
        summary ""
    fi

    info "Done: $(hl "${created}") created, $(hl "${updated}") updated, $(hl "${reopened}") reopened, $(hl "${closed}") closed, $(hl "${orphaned}") orphaned"
}

# Append a line to the job summary, and echo it so the log shows the report too
summary() {
    printf '%s\n' "$*"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        printf '%s\n' "$*" >> "${GITHUB_STEP_SUMMARY}"
    fi
}
# Run a mutating gh command, or print it under DRY_RUN
gh_mutate() {
    if [[ "${CFG_DRY_RUN}" == "true" ]]; then
        info "DRY-RUN: gh $*"
    else
        gh "$@"
    fi
}

## ── Entry point ─────────────────────────────────────────────────────────────
# Guarded so a this file can be sourced and exercise the helpers above
# in isolation without running the whole thing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
