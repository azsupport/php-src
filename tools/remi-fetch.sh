#!/bin/sh
# remi-fetch.sh - the RPM specs and patches of Remi Collet's repository, the
# sources of rpms.remirepo.net, from its git server https://git.remirepo.net/cgit/
# (the GitHub repository remicollet/remirepo carries only its issues since 2017):
# what his PHP packages (php56 ... php85, the SCL ones) and PECL extensions carry
# beyond his php-src-security branches and the PHP releases. That server is closed
# to the sandbox of Claude Code, GitHub is not. Workflow: .github/workflows/remi-fetch.yml.
#
# Usage:
#   sh tools/remi-fetch.sh fetch <out dir> <regex>...
#       every repository of the cgit index whose path matches one of the extended
#       regular expressions (grep -E): of each of its branches the specs and the
#       patches, and its log; no regex: the index only
#   sh tools/remi-fetch.sh push <out dir>
#       commit what a fetch wrote into the branch runs of azsupport/azsupport,
#       distro/remi/<YYYY-MM-DD>/ (needs RUNS_TOKEN)
# Environment:
#   REMI_URL    the cgit server (default https://git.remirepo.net/cgit)
#   RUNS_TOKEN  push: a token with Contents read and write on azsupport/azsupport
#               (the secret of tools/runs-report.sh)
#   RUNS_REMOTE push: the repository to commit to instead (a path, for a test)
# What a fetch writes into <out dir>:
#   index.txt                     the paths of the repositories of the index
#   <repo>/<branch>/              the *.spec, *.patch, *.diff, *.ini, *.conf,
#                                 *.macros and *.txt files of the branch (as in
#                                 the tree; files over 1 MB are left out)
#   <repo>/<branch>/log.txt       the last 60 commits of the branch
#   report.md                     the clone URL, the branches and files of each
#                                 repository, what failed (a push puts it at
#                                 distro/remi/<date>/<run id>.md)
#   taken.txt                     "<repo>" per repository taken
# The exit status of a fetch is 1 when a repository failed: the rest is still
# written, and report.md says what failed.

set -u
set -f
cmd="${1:-}"
[ $# -gt 0 ] && shift
usage() {
    echo "usage: sh tools/remi-fetch.sh fetch <out dir> [<regex>...]" >&2
    echo "       sh tools/remi-fetch.sh push <out dir>" >&2
    exit 2
}
w="$(mktemp -d)"
trap 'rm -rf "$w"' EXIT
base_url="${REMI_URL:-https://git.remirepo.net/cgit}"

# ---------------------------------------------------------------------------- push
if [ "$cmd" = push ]; then
    [ $# -eq 1 ] || usage
    src="$(cd "$1" && pwd)" || exit 1
    remote="${RUNS_REMOTE:-}"
    if [ -z "$remote" ]; then
        if [ -z "${RUNS_TOKEN:-}" ]; then
            echo "::warning title=remi fetch::RUNS_TOKEN is not set: nothing committed to azsupport/azsupport (branch runs)"
            exit 0
        fi
        remote="https://x-access-token:${RUNS_TOKEN}@github.com/azsupport/azsupport.git"
    fi
    hide() { sed 's#x-access-token:[^@]*@#x-access-token:***@#g'; }
    day="$(date -u +%Y-%m-%d)"
    run="${GITHUB_RUN_ID:-0}"
    r="$w/runs"
    if ! git clone -q --depth 1 --filter=blob:none --sparse --branch runs --single-branch "$remote" "$r" 2>"$w/err"; then
        echo "::error title=remi fetch::clone of azsupport/azsupport (runs) failed: $(hide < "$w/err" | tail -n 2 | tr '\n' ' ')"
        exit 1
    fi
    git -C "$r" config user.name 'github-actions[bot]'
    git -C "$r" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
    base="distro/remi/$day"
    git -C "$r" sparse-checkout set --no-cone "/$base/" > /dev/null 2>&1
    mkdir -p "$r/$base"
    cp "$src/index.txt" "$r/$base/index.txt" 2>/dev/null
    # each repository in the place of that of an earlier run of the day
    if [ -f "$src/taken.txt" ]; then
        while read -r d; do
            [ -n "$d" ] && [ -d "$src/$d" ] || continue
            rm -rf "${r:?}/$base/$d"
            mkdir -p "$r/$base/$(dirname "$d")"
            cp -R "$src/$d" "$r/$base/$d"
        done < "$src/taken.txt"
    fi
    {
        echo "# remi-fetch — $day"
        echo
        echo "- run: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-azsupport/php-src}/actions/runs/$run (attempt ${GITHUB_RUN_ATTEMPT:-1})"
        echo "- commit: ${GITHUB_SHA:-?} $(git log -1 --format=%s 2>/dev/null)"
        echo "- written: $(date -u '+%Y-%m-%d %H:%M UTC')"
        echo "- files: $base/<repository>/<branch>/ (specs, patches, log.txt), $base/index.txt"
        echo
        if [ -s "$src/report.md" ]; then cat "$src/report.md"; else echo "(no report: the fetch wrote none)"; fi
    } > "$r/$base/$run.md"
    git -C "$r" add -A "$base"
    git -C "$r" commit -q -m "remi-fetch: run $run" || { echo "::error title=remi fetch::commit failed"; exit 1; }
    # other runs push into runs too: on a refused push, rebase and again
    i=0
    : > "$w/err"
    while [ $i -lt 6 ]; do
        i=$((i + 1))
        if git -C "$r" push -q origin HEAD:runs 2>>"$w/err"; then
            echo "remi fetch: $base/$run.md"
            exit 0
        fi
        sleep $((i * 5))
        git -C "$r" pull -q --rebase origin runs 2>>"$w/err" || git -C "$r" rebase --abort 2>/dev/null
    done
    echo "::error title=remi fetch::push to azsupport/azsupport (runs) failed: $(hide < "$w/err" | tail -n 3 | tr '\n' ' ')"
    exit 1
fi

# --------------------------------------------------------------------------- fetch
[ "$cmd" = fetch ] && [ $# -ge 1 ] || usage
out="$1"
shift
mkdir -p "$out" && out="$(cd "$out" && pwd)" || exit 1
rep="$out/report.md"
: > "$rep"
: > "$out/taken.txt"
say() { printf '%s\n' "$*" >> "$rep"; }
note() { printf '%s remi-fetch: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
failed=0

# the index: cgit pages of 50 repositories (?ofs=N) until a page adds none
: > "$w/all"
ofs=0
while [ $ofs -lt 20000 ]; do
    if ! curl -fsSL --retry 3 -m 60 "$base_url/?ofs=$ofs" -o "$w/page" 2>"$w/err"; then
        say "- index page ofs=$ofs: $(tail -n 1 "$w/err")"
        [ $ofs -eq 0 ] && failed=1
        break
    fi
    # links of the repositories: href='/cgit/<path>/' (no query strings)
    tr '"' "'" < "$w/page" | grep -o "href='/cgit/[^'?]*/'" | sed "s#^href='/cgit/##; s#/'\$##" |
        grep -v -E '^(about|$)' > "$w/links"
    n_before=$(wc -l < "$w/all")
    sort -u "$w/all" "$w/links" > "$w/all2" && mv "$w/all2" "$w/all"
    n_after=$(wc -l < "$w/all")
    [ "$n_after" -gt "$n_before" ] || break
    ofs=$((ofs + 50))
done
# repository paths only: no tree/log/commit pages of a repository
grep -v -E '/(tree|log|commit|diff|refs|summary|plain|snapshot|patch|stats|about)(/|$)' "$w/all" > "$out/index.txt"
say "### Index of $base_url"
say ""
say "$(wc -l < "$out/index.txt") repositories (index.txt)."
say ""
note "index: $(wc -l < "$out/index.txt") repositories"

[ $# -gt 0 ] || { [ $failed -eq 0 ]; exit $?; }

: > "$w/want"
for re in "$@"; do
    grep -E -- "$re" "$out/index.txt" >> "$w/want" || say "- no repository matches \`$re\`"
done
sort -u "$w/want" > "$w/want2"

while read -r repo; do
    [ -n "$repo" ] || continue
    g="$w/git"
    rm -rf "$g"
    url=""
    for u in "$base_url/$repo" "$base_url/$repo.git" "${base_url%/cgit}/$repo"; do
        if git clone -q --bare "$u" "$g" 2>"$w/err"; then
            url="$u"
            break
        fi
        rm -rf "$g"
    done
    if [ -z "$url" ]; then
        say "- **$repo**: clone failed: $(tail -n 1 "$w/err")"
        failed=1
        continue
    fi
    note "$repo ($url)"
    say "#### $repo"
    say ""
    say "Clone: $url"
    say ""
    git -C "$g" for-each-ref --format='%(refname:short)' refs/heads > "$w/branches"
    while read -r b; do
        d="$out/$repo/$b"
        mkdir -p "$d"
        git -C "$g" log -60 --date=short --format='%h %ad %an %s' "$b" > "$d/log.txt" 2>/dev/null
        n=0
        git -C "$g" ls-tree -r -l "$b" > "$w/tree"
        while read -r mode type sha size path; do
            [ "$type" = blob ] || continue
            case "$path" in
                *.spec|*.patch|*.diff|*.ini|*.conf|*.macros|*.txt) ;;
                *) continue ;;
            esac
            [ "$size" -le 1048576 ] 2>/dev/null || continue
            mkdir -p "$d/$(dirname "$path")"
            git -C "$g" cat-file blob "$sha" > "$d/$path" && n=$((n + 1))
        done < "$w/tree"
        say "- \`$b\`: $n files, last commit $(head -n 1 "$d/log.txt")"
    done < "$w/branches"
    say ""
    echo "$repo" >> "$out/taken.txt"
done < "$w/want2"

exit $failed
