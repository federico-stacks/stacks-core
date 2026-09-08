#!/usr/bin/env bash
#
# Keeps one GitHub issue per flaky test in step with the nightly's results.
#
# Two phases, both driven by observed-tests.jsonl from flaky_report.sh:
#
#   1. Tests that FAILED    -> file a new issue, or comment on the existing one
#   2. Tests that PASSED    -> close the issue once the test has been quiet for
#                              QUIET_AFTER scheduled nightly runs
#   2b. Tests never SEEN    -> close the issue once the test has gone unobserved
#                              for ORPHAN_AFTER runs (renamed, deleted, excluded)
#
# A test absent from one run is left alone: it may simply not have run (a
# narrowed `only-tests` matrix, an excluded test, or a job that never reported).
# One run's absence says nothing, but absence that persists says plenty, so an
# issue closes once its test has gone unobserved for ORPHAN_AFTER runs. That
# needs no judgement about *why* it vanished, which is the point: renamed,
# deleted and excluded are indistinguishable from the results alone.
#
# One issue per test, so the issue becomes that test's record: every nightly run
# in which it fails appends a comment. Evidence is written as text rather than
# only as a link, because Actions job logs are deleted after 90 days (the API
# returns HTTP 410) while the issue is permanent.
#
# Closing rather than labelling is deliberate: the failure phase already reopens
# a closed issue, so closing composes with behaviour that already exists, and
# open-vs-closed is a stronger signal than a label because GitHub hides closed
# issues by default. The `flaky` label is preserved on close.
#
# Required env vars:
#   GH_TOKEN            - token with issues:write on GITHUB_REPOSITORY
#   GITHUB_REPOSITORY   - owner/repo to file issues against
#
# Optional env vars:
#   OBSERVED_TESTS_FILE - JSONL produced by flaky_report.sh
#                         (default: observed-tests.jsonl)
#   FLAKY_LABEL         - label applied to every issue, created if absent
#                         (default: flaky)
#   FLAKY_LABEL_COLOR   - colour used only when creating the label
#                         (default: 58BCF1, matching stacks-network/stacks-core)
#   MAX_NEW_ISSUES      - cap on issues CREATED in one run. Commenting on issues
#                         that already exist is never capped. Anything deferred
#                         is named in the job summary, never dropped silently
#                         (default: 10)
#   QUIET_AFTER         - how many quiet scheduled runs before an issue is
#                         closed. 0 closes as soon as the test passes
#                         (default: 14)
#   QUIET_RUN_EVENTS    - comma-separated workflow event names that count as a
#                         chance for the test to fail; surrounding whitespace is
#                         trimmed, so "schedule, workflow_dispatch" works.
#                         Scheduled runs are always full-width, which is what
#                         makes them a fair measure; `workflow_dispatch` can be
#                         added to exercise the threshold without waiting for
#                         the cron
#                         (default: schedule)
#   ORPHAN_AFTER        - how many runs a test may go *unobserved* before its
#                         issue is closed as no longer watched. Must be greater
#                         than QUIET_AFTER - see close_quiet_issues()
#                         (default: 30)
#   NIGHTLY_WORKFLOW    - workflow whose run history is counted
#                         (default: tests-flaky-nightly.yml)
#   DRY_RUN             - "true" to print every mutation instead of performing it
#
# Not in scope: classifying failures by mode, failure-rate tracking, and job-log
# links. Those are separate steps.
#
# Exit behaviour:
#   Exits 0 when triage completed. Test failures are reported by the test jobs
#   themselves; failing here would only hide the summary this produces.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

## Load logging functions
# shellcheck disable=SC1091
source "${script_dir}/logging.sh"

## --- Configuration ----------------------------------------------------------
repo="${GITHUB_REPOSITORY:-}"
observed_tests_file="${OBSERVED_TESTS_FILE:-observed-tests.jsonl}"
flaky_label="${FLAKY_LABEL:-flaky}"
flaky_label_color="${FLAKY_LABEL_COLOR:-58BCF1}"
max_new_issues="${MAX_NEW_ISSUES:-10}"
quiet_after="${QUIET_AFTER:-14}"
quiet_run_events="${QUIET_RUN_EVENTS:-schedule}"
orphan_after="${ORPHAN_AFTER:-30}"
nightly_workflow="${NIGHTLY_WORKFLOW:-tests-flaky-nightly.yml}"
dry_run="${DRY_RUN:-false}"

# Marker carrying the fully qualified test name. Dedup keys on this rather than
# on the issue title: test names share long prefixes, so title or prefix
# matching would eventually merge two distinct tests into one issue.
id_marker_prefix="test-id"

# Heading that starts every evidence comment. Also how the close phase finds the
# date of the most recent failure, so the two must stay in step.
failure_heading="### Failure - "

# Long enough that captured output containing triple backticks cannot break out
fence='`````'

run_url="${GITHUB_SERVER_URL:-https://github.com}/${repo}/actions/runs/${GITHUB_RUN_ID:-}"
today="$(date -u +%Y-%m-%d)"

## ── Check for required binaries ─────────────────────────────────────────────
missing=0
for cmd in gh jq; do
    if ! command -v "${cmd}" > /dev/null 2>&1; then
        error "Missing required command: $(hl "${cmd}")"
        missing=1
    fi
done
[[ "${missing}" -eq 1 ]] && exit 1

## ── Validate required inputs ────────────────────────────────────────────────
if [[ -z "${repo}" ]]; then
    error "GITHUB_REPOSITORY is not set"
    exit 1
fi
if [[ -z "${GH_TOKEN:-}" ]]; then
    error "GH_TOKEN is not set (needs issues:write on $(hl "${repo}"))"
    exit 1
fi

# ORPHAN_AFTER must exceed QUIET_AFTER, and this is load-bearing rather than
# cosmetic - it is what stops a single job that failed to report from closing a
# healthy test's issue. See close_quiet_issues() for the argument. Refuse to run
# on a configuration that quietly breaks it.
if (( orphan_after <= quiet_after )); then
    error "$(hl "ORPHAN_AFTER") (${orphan_after}) must be greater than $(hl "QUIET_AFTER") (${quiet_after})"
    error "Otherwise one unreported test job could close the issue of a passing test."
    exit 1
fi

## ── Main ────────────────────────────────────────────────────────────────────
main() {
    local existing_issues existing_labels observed_count failed_count
    local created=0 updated=0 reopened=0 closed=0 orphaned=0
    local -a deferred=()

    ## Preflight: issues must be enabled
    # Forks have Issues disabled by default, and every gh issue call then fails
    # with "repository has disabled issues". Check once, with the fix inline,
    # rather than letting the first API call fail opaquely.
    if [[ "$(gh api "repos/${repo}" --jq '.has_issues')" != "true" ]]; then
        error "Issues are disabled on $(hl "${repo}"), so no issue can be filed!"
        return 1
    fi

    ## Precondition: this run must have observed something
    # -s, not -f: flaky_report.sh creates the file and *then* returns early when a
    # run produced no JUnit reports at all, so the file exists and is empty. That
    # is the case worth catching, and the artifact download is continue-on-error,
    # so a failed download reaches here looking like a run in which nothing ran.
    #
    # Checked once for the whole script rather than per phase. With no
    # observations there is nothing any phase can conclude: filing is already a
    # no-op because no test is marked failed, and closing must not treat "we saw
    # nothing" as "every test passed" - see step 5b, where absence becomes
    # actionable and this guard is what keeps a broken download from closing
    # every issue.
    if [[ ! -s "${observed_tests_file}" ]]; then
        warn "No tests were observed in this run - nothing to do"
        summary "## Flaky test issues"
        summary ""
        summary "**No test results were observed**, so no issue was filed, updated or closed."
        summary "This is not the same as a run in which no test failed - check the archive"
        summary "and test jobs."
        summary ""
        return 0
    fi

    observed_count=$(grep -c '' "${observed_tests_file}" || true)
    failed_count=$(jq -s '[.[] | select(.status == "fail")] | length' "${observed_tests_file}")
    info "Observed $(hl "${observed_count}") test(s), $(hl "${failed_count}") failing, on $(hl "${repo}")"

    ## Ensure the label exists
    # Created only when absent, so a label whose color or description someone has
    # customized is left alone. It exists on stacks-network/stacks-core but not
    # necessarily on a fork, and `gh issue create --label` fails on a missing label.
    # Read the list into a variable rather than piping gh into grep -q: grep -q
    # exits on the first match, which can SIGPIPE gh, and under pipefail that
    # would make this condition read false and send us on to create a label that
    # already exists.
    existing_labels=$(gh label list --repo "${repo}" --limit 200 --json name --jq '.[].name')

    if grep -qxF "${flaky_label}" <<< "${existing_labels}"; then
        info "Label already exists: $(hl "${flaky_label}")"
    else
        info "Creating label: $(hl "${flaky_label}")"
        gh_mutate label create "${flaky_label}" --repo "${repo}" \
            --color "${flaky_label_color}" \
            --description "Test that fails intermittently in CI"
    fi

    ## Load the issues we already filed, once, for both phases
    # `comments` is needed by the close phase to date each issue's last failure.
    existing_issues="$(mktemp)"
    gh issue list --repo "${repo}" --label "${flaky_label}" --state all \
        --limit 500 --json number,state,body,comments > "${existing_issues}"

    info "Found $(hl "$(jq 'length' "${existing_issues}")") existing $(hl "${flaky_label}") issue(s)"

    file_failure_issues "${existing_issues}"
    close_quiet_issues "${existing_issues}"

    # Best-effort tidiness only: on an error path set -e aborts before this
    # runs. Acceptable because the runner is destroyed at the end of the job
    # and the payload is tens of KB - not worth an EXIT trap to guarantee.
    rm -f "${existing_issues}"

    report_summary
}

## ── Phase 1: tests that failed ──────────────────────────────────────────────
file_failure_issues() {
    local existing_issues="$1"
    local record name duration excerpt marker comment_file body_file
    local match number state url

    while IFS= read -r record; do
        name=$(jq -r '.name' <<< "${record}")
        duration=$(jq -r '.time' <<< "${record}")
        excerpt=$(jq -r '.excerpt' <<< "${record}")
        [[ -z "${name}" ]] && continue

        marker="<!-- ${id_marker_prefix}: ${name} -->"

        # The evidence comment, identical whether the issue is new or existing
        comment_file="$(mktemp)"
        {
            echo "${failure_heading}${today}"
            echo
            echo "- **Run:** [${GITHUB_RUN_ID:-unknown}](${run_url})"
            echo "- **Commit:** \`${GITHUB_SHA:-unknown}\` on \`${GITHUB_REF_NAME:-unknown}\`"
            echo "- **Duration:** ${duration}s"
            echo
            echo "${fence}text"
            printf '%s\n' "${excerpt}"
            echo "${fence}"
            echo
            echo "Full test output is in the run's job log, which is subject to GitHub retention policy."
        } > "${comment_file}"

        # Exact-match the marker against the bodies we already have.
        #
        # jq joins the fields with tabs and `read` splits them apart again, here
        # and at the reads in phase 2. This is safe because @tsv escapes any tab,
        # newline, CR or backslash *inside* a value as a two-character sequence,
        # so a record is always one line carrying exactly the field count jq
        # emitted - no value can mis-split the row. The trade-off is that a
        # multi-line value would arrive with a literal `\n` in it, which is why
        # the failure records above are read as JSON: their excerpt is multi-line
        # by design. No match leaves both fields empty.
        #
        # Assigned first and read second, rather than reading straight from the
        # substitution: `read <<< "$(jq ...)"` reports read's status, not jq's,
        # so a jq failure would be swallowed and read as "no match" - and this
        # script would then file a duplicate issue for a test that already has
        # one. As an assignment, a jq failure aborts under set -e instead.
        match=$(jq -r --arg marker "${marker}" '
            map(select(.body != null and (.body | contains($marker))))
            | if length == 0 then "" else [.[0].number, .[0].state] | @tsv end
        ' "${existing_issues}")
        IFS=$'\t' read -r number state <<< "${match}"

        if [[ -z "${number}" ]]; then
            if (( created >= max_new_issues )); then
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
                echo "> Filed automatically by \`tests-flaky-nightly.yml\`."
                echo
                echo "${marker}"
            } > "${body_file}"

            info "Creating issue for $(hl "${name}")"
            url=$(gh_mutate issue create --repo "${repo}" \
                --title "[Flaky Test] ${name}" \
                --label "${flaky_label}" \
                --body-file "${body_file}" || true)
            rm -f "${body_file}"

            # Post the first evidence as a comment too, so a new issue and an old
            # one carry the same shape of history
            if [[ -n "${url}" ]]; then
                number="${url##*/}"
                gh_mutate issue comment "${number}" --repo "${repo}" \
                    --body-file "${comment_file}"
            elif [[ "${dry_run}" == "true" ]]; then
                info "DRY-RUN: gh issue comment <new issue> --repo ${repo} --body-file <evidence>"
            fi
            created=$(( created + 1 ))
        else
            if [[ "${state}" == "CLOSED" ]]; then
                info "Reopening #${number} for $(hl "${name}")"
                gh_mutate issue reopen "${number}" --repo "${repo}"
                reopened=$(( reopened + 1 ))
            fi

            info "Adding evidence to #${number} for $(hl "${name}")"
            gh_mutate issue comment "${number}" --repo "${repo}" \
                --body-file "${comment_file}"
            updated=$(( updated + 1 ))
        fi

        rm -f "${comment_file}"
    done < <(jq -c 'select(.status == "fail")' "${observed_tests_file}")
}

## ── Phase 2: tests that have gone quiet, by passing or by vanishing ─────────
#
# Two closes sharing one counter - the number of qualifying runs since the test
# last failed:
#
#   pass   + quiet_count >= QUIET_AFTER   -> "went quiet"   (positive evidence)
#   absent + quiet_count >= ORPHAN_AFTER  -> "not watched"   (negative evidence)
#
# ORPHAN_AFTER > QUIET_AFTER is what makes the second one safe, and the reasoning
# is worth spelling out. For the absent branch to fire, the issue must still be
# OPEN at quiet_count >= ORPHAN_AFTER. But any single run in which the test was
# *observed passing* at quiet_count >= QUIET_AFTER would already have closed it
# on the honest message, and a closed issue is skipped below. So an issue can
# only reach the orphan threshold if the test was genuinely never observed in
# between: one crashed job cannot get it there, because the test's other passing
# runs close the issue first. The inequality is validated at startup.
close_quiet_issues() {
    local existing_issues="$1"
    local quiet_runs number state test_id test_status last_failure quiet_count
    local comment reason
    local -A observed_status=()

    # Status of every test that ran, so "passed" can be told apart from "did not
    # run". Without this a narrowed `only-tests` matrix would look like a run in
    # which every other test passed, and would close their issues.
    while IFS=$'\t' read -r test_id test_status; do
        observed_status["${test_id}"]="${test_status}"
    done < <(jq -r '[.name, .status] | @tsv' "${observed_tests_file}")

    # Runs that gave every test a chance to fail. One call for the whole phase.
    #
    # Each event name is trimmed and empties dropped, matching how
    # bitcoin_tests.sh already parses ONLY_TESTS. QUIET_RUN_EVENTS is a free-text
    # workflow input, so "schedule, workflow_dispatch" is what a human naturally
    # types - and without the trim the second name keeps its leading space,
    # matches no event and is silently dropped. That fails safe, since an
    # undercount only delays closing, but gives no clue why nothing closed.
    quiet_runs=$(gh run list --repo "${repo}" --workflow "${nightly_workflow}" \
        --limit 200 --json event,createdAt,conclusion \
        | jq -c --arg events "${quiet_run_events}" '
            ($events
             | split(",")
             | map(gsub("^\\s+|\\s+$"; ""))
             | map(select(length > 0))) as $want
            | [ .[]
                | select((.event as $e | $want | index($e)) and .conclusion != "cancelled")
                | .createdAt ]')

    # A zero count means nothing can ever close. Silent before, and the most
    # likely cause is a typo in the event names rather than a genuine absence.
    if [[ "$(jq 'length' <<< "${quiet_runs}")" -eq 0 ]]; then
        warn "No $(hl "${quiet_run_events}") run(s) found - nothing can close as quiet"
    fi

    info "Counting quiet runs against $(hl "$(jq 'length' <<< "${quiet_runs}")") $(hl "${quiet_run_events}") run(s)"

    while IFS=$'\t' read -r number state test_id last_failure; do
        [[ -z "${test_id}" ]] && continue

        # Only open issues can be closed
        [[ "${state}" != "OPEN" ]] && continue

        # Needed by both branches below, so computed before deciding which one
        # applies. An issue with no failure comment at all counts as infinitely
        # quiet, because every run then sorts after "no failure".
        quiet_count=$(jq --arg last "${last_failure}" \
            '[.[] | select($last == "" or . > $last)] | length' <<< "${quiet_runs}")

        case "${observed_status[${test_id}]:-absent}" in
            fail)
                # Phase 1 just recorded a failure; nothing to close
                continue
                ;;
            pass)
                (( quiet_count >= quiet_after )) || continue
                reason="quiet"
                ;;
            absent)
                (( quiet_count >= orphan_after )) || continue
                reason="orphan"
                ;;
            *)
                # Only pass/fail are ever written, so this means the results
                # format changed. Skip rather than guess at a close.
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

        gh_mutate issue close "${number}" --repo "${repo}" --comment "${comment}"
    done < <(jq -r --arg prefix "${id_marker_prefix}" --arg heading "${failure_heading}" '
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

## ── Closing comments ────────────────────────────────────────────────────────
#
# Both say what happened and that no action is needed. Kept as functions so the
# loop above reads as decisions rather than prose.

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

# Deliberately vague about the cause: renamed, deleted and excluded are
# indistinguishable from the results, and claiming one would mislead triage.
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

## ── Helpers ─────────────────────────────────────────────────────────────────
#
# Defined after the phases on purpose: bash resolves function names when they
# are called, not when the file is parsed, so main() can read top-down while the
# helpers it uses sit out of the way below.

report_summary() {
    summary "## Flaky test issues"
    summary ""
    if [[ "${dry_run}" == "true" ]]; then
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
        summary "The \`MAX_NEW_ISSUES\` cap of ${max_new_issues} was reached, so no issue was"
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
    if [[ "${dry_run}" == "true" ]]; then
        info "DRY-RUN: gh $*"
        return 0
    fi
    gh "$@"
}

## ── Entry point ─────────────────────────────────────────────────────────────
# Guarded so a test harness can source this file and exercise the helpers above
# in isolation without running the whole thing.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
