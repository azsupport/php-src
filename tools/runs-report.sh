#!/bin/sh
# runs-report.sh - commit the report of a run of this repository's workflows into
# the branch "runs" of the private repository azsupport/azsupport, so that it is
# read with git (git fetch origin runs) and not from the logs of the jobs through
# the API (azsupport/azsupport, tools/brief.py shows the latest ones).
#
# Usage: sh tools/runs-report.sh <report.md> <part>
#   <report.md>  the job summary of the run (what the report scripts wrote)
#   <part>       the part of the run in the file name (x86-64-v3, x86-64-v2...)
# Environment:
#   RUNS_TOKEN   a fine-grained token with Contents read and write on
#                azsupport/azsupport (secret of this repository); without it the
#                report is not committed (a warning) and the run does not fail
#   RUNS_REMOTE  the repository to commit to instead (a path, for a test)
#   RUNS_INPUTS  the inputs of the run ("release=15.1 cputype=x86-64-v3 ...")
#   RUNS_STEPS   the outcomes of its steps ("build=success report=failure ...")
#   GITHUB_*     as GitHub Actions sets them
# The file: <workflow>/<YYYY-MM-DD>/<run id>-<part>.md (workflow: the name of its
# file without .yml), a header (run, commit, inputs, steps, time) and the report.
# A failure here never fails the run: it ends in a warning.

set -u
rep="${1:?usage: sh tools/runs-report.sh <report.md> <part>}"
part="${2:?usage: sh tools/runs-report.sh <report.md> <part>}"
remote="${RUNS_REMOTE:-}"
if [ -z "$remote" ]; then
    if [ -z "${RUNS_TOKEN:-}" ]; then
        echo "::warning title=runs report::RUNS_TOKEN is not set: the report is not committed to azsupport/azsupport (branch runs)"
        exit 0
    fi
    remote="https://x-access-token:${RUNS_TOKEN}@github.com/azsupport/azsupport.git"
fi
wf="${GITHUB_WORKFLOW_REF:-}"; wf="${wf%%@*}"; wf="${wf##*/}"; wf="${wf%.yml}"
[ -n "$wf" ] || wf="run"
day="$(date -u +%Y-%m-%d)"
run="${GITHUB_RUN_ID:-0}"
file="$wf/$day/$run-$part.md"
subject="$(git log -1 --format=%s 2>/dev/null)"
w="$(mktemp -d)"
trap 'rm -rf "$w"' EXIT
r="$w/r"
warn() { echo "::warning title=runs report::$*"; exit 0; }
hide() { sed 's#x-access-token:[^@]*@#x-access-token:***@#g'; }

if git clone -q --depth 1 --branch runs --single-branch "$remote" "$r" 2>"$w/err"; then
    :
elif grep -q -i -E 'not found in upstream|Remote branch runs not found' "$w/err"; then
    # no branch runs yet: the first report starts it
    git init -q "$r" && git -C "$r" checkout -q --orphan runs && git -C "$r" remote add origin "$remote" ||
        warn "git init failed"
    printf '%s\n' "# Reports of the runs of azsupport/php-src" "" \
        "One file per run and part: <workflow>/<date>/<run id>-<part>.md, written by tools/runs-report.sh of azsupport/php-src." \
        > "$r/README.md"
else
    warn "clone of azsupport/azsupport (runs) failed: $(hide < "$w/err" | tail -n 2 | tr '\n' ' ')"
fi

mkdir -p "$r/$wf/$day"
{
    echo "# $wf — $part — $day"
    echo
    echo "- run: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-azsupport/php-src}/actions/runs/$run (attempt ${GITHUB_RUN_ATTEMPT:-1})"
    echo "- commit: ${GITHUB_SHA:-?} $subject"
    echo "- inputs: ${RUNS_INPUTS:-}"
    echo "- steps: ${RUNS_STEPS:-}"
    echo "- written: $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo
    if [ -s "$rep" ]; then cat "$rep"; else echo "(no report: $rep is empty or missing)"; fi
} > "$r/$file"
git -C "$r" add -A
# the identity of the commit and of a rebase on a refused push
git -C "$r" config user.name 'github-actions[bot]'
git -C "$r" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
git -C "$r" commit -q -m "$wf $part: run $run" || warn "commit failed"

# the parts of a run push at the same time: on a refused push, rebase and again
i=0
while [ $i -lt 5 ]; do
    i=$((i + 1))
    if git -C "$r" push -q origin HEAD:runs 2>"$w/err"; then
        echo "runs report: $file"
        exit 0
    fi
    sleep $((i * 3))
    git -C "$r" pull -q --rebase origin runs 2>>"$w/err" || true
done
warn "push to azsupport/azsupport (runs) failed: $(hide < "$w/err" | tail -n 3 | tr '\n' ' ')"
