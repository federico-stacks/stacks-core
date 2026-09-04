#!/usr/bin/env bash
#
# Files one GitHub issue per flaky test, from the results of flaky_report.sh.
#
# One issue per test, so the issue becomes that test's record: every nightly run
# in which it fails appends a comment. Evidence is written as text rather than
# only as a link, because Actions job logs are deleted after 90 days (the API
# returns HTTP 410) while the issue is permanent.
#
# Required env vars:
#   GH_TOKEN          - token with issues:write on GITHUB_REPOSITORY
#   GITHUB_REPOSITORY - owner/repo to file issues against
#
# Optional env vars:
#   FAILED_TESTS_FILE - JSONL produced by flaky_report.sh
#                       (default: failed-tests.jsonl)
#   FLAKY_LABEL       - label applied to every issue, created if absent
#                       (default: flaky)
#   FLAKY_LABEL_COLOR - colour used only when creating the label
#                       (default: 58BCF1, matching stacks-network/stacks-core)
#   MAX_NEW_ISSUES    - cap on issues CREATED in one run. Commenting on issues
#                       that already exist is never capped. Anything deferred is
#                       named in the job summary, never dropped silently
#                       (default: 10)
#   DRY_RUN           - "true" to print every mutation instead of performing it
#
# Not in scope: classifying failures by mode, failure-rate tracking, dormancy,
# job-log links. Those are separate steps so each can be reviewed on its own.
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
failed_tests_file="${FAILED_TESTS_FILE:-failed-tests.jsonl}"
flaky_label="${FLAKY_LABEL:-flaky}"
flaky_label_color="${FLAKY_LABEL_COLOR:-58BCF1}"
max_new_issues="${MAX_NEW_ISSUES:-10}"
dry_run="${DRY_RUN:-false}"

# Marker carrying the fully qualified test name. Dedup keys on this rather than
# on the issue title: test names share long prefixes, so title or prefix
# matching would eventually merge two distinct tests into one issue.
id_marker_prefix="test-id"

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

## ── Main ────────────────────────────────────────────────────────────────────
main() {
    local failed_count existing_labels existing_issues
    local record name duration excerpt marker comment_file body_file
    local match number state url
    local created=0 updated=0 reopened=0
    local -a deferred=()

    ## Preflight: issues must be enabled
    # Forks have Issues disabled by default, and every gh issue call then fails
    # with "repository has disabled issues". Check once, with the fix inline,
    # rather than letting the first API call fail opaquely.
    if [[ "$(gh api "repos/${repo}" --jq '.has_issues')" != "true" ]]; then
        error "Issues are disabled on $(hl "${repo}"), so no issue can be filed!"
        return 1
    fi

    ## Nothing to do?
    if [[ ! -s "${failed_tests_file}" ]]; then
        info "No failures in $(hl "${failed_tests_file}") - nothing to file"
        summary "## Flaky test issues"
        summary ""
        summary "No failing tests, so no issues were filed or updated."
        summary ""
        return 0
    fi

    failed_count=$(grep -c '' "${failed_tests_file}")
    info "Filing issues for $(hl "${failed_count}") failing test(s) on $(hl "${repo}")..."

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

    ## Load the issues we already filed
    # One listing, reused for every test: a few API calls instead of one per test.
    existing_issues="$(mktemp)"

    gh issue list --repo "${repo}" --label "${flaky_label}" --state all \
        --limit 500 --json number,state,body > "${existing_issues}"

    info "Found $(hl "$(jq 'length' "${existing_issues}")") existing $(hl "${flaky_label}") issue(s)"

    ## File or update one issue per failing test
    while IFS= read -r record; do
        name=$(jq -r '.name' <<< "${record}")
        duration=$(jq -r '.time' <<< "${record}")
        excerpt=$(jq -r '.excerpt' <<< "${record}")
        [[ -z "${name}" ]] && continue

        marker="<!-- ${id_marker_prefix}: ${name} -->"

        # The evidence comment, identical whether the issue is new or existing
        comment_file="$(mktemp)"
        {
            echo "### Failure - ${today}"
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

        # Exact-match the marker against the bodies we already have
        match=$(jq -r --arg marker "${marker}" '
            map(select(.body != null and (.body | contains($marker))))
            | if length == 0 then "" else "\(.[0].number) \(.[0].state)" end
        ' "${existing_issues}")

        if [[ -z "${match}" ]]; then
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
            number="${match%% *}"
            state="${match##* }"

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
    done < "${failed_tests_file}"

    rm -f "${existing_issues}"

    ## Report
    summary "## Flaky test issues"
    summary ""
    if [[ "${dry_run}" == "true" ]]; then
        summary "\`DRY_RUN\` was set: no issues were created or updated."
        summary ""
    fi
    summary "| | |"
    summary "| --- | --- |"
    summary "| Failing tests | ${failed_count} |"
    summary "| Issues created | ${created} |"
    summary "| Issues updated | ${updated} |"
    summary "| Issues reopened | ${reopened} |"
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

    info "Done: $(hl "${created}") created, $(hl "${updated}") updated, $(hl "${reopened}") reopened"
}

## ── Helpers ─────────────────────────────────────────────────────────────────
#
# Defined after main() on purpose: bash resolves function names when they are
# called, not when the file is parsed, so main() can read top-down while the
# helpers it uses sit out of the way below.

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
