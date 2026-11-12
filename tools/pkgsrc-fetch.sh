#!/bin/sh
# pkgsrc-fetch.sh - what a review of the patches of pkgsrc needs from hosts that only
# a runner reaches: the vulnerability list of pkgsrc (pkg-vulnerabilities, from
# cdn.netbsd.org) and files that a pkgsrc patch is compared with (a release archive,
# an upstream patch) from any https URL. The pkgsrc tree itself, its quarterly
# branches and pkgsrc-wip are read from their GitHub mirrors (NetBSD/pkgsrc,
# NetBSD/pkgsrc-wip). Workflow: .github/workflows/pkgsrc-fetch.yml.
#
# Usage:
#   sh tools/pkgsrc-fetch.sh fetch <out dir> [<item>...]
#       <item>   <url>                     the file as it is (at most 20 MiB)
#                <url>=<sha256>            the same, with its SHA-256 checked
#                <url>[=<sha256>]::<member>[,<member>...]
#                                          only these members of an archive
#                                          (.tar.gz, .tgz, .tar.bz2, .tar.xz, .zip);
#                                          a member is a path in the archive, a
#                                          leading "*/" stands for its top directory
#       pkg-vulnerabilities is fetched in any case.
#   sh tools/pkgsrc-fetch.sh push <out dir>
#       commit what a fetch wrote into the branch runs of azsupport/azsupport,
#       distro/pkgsrc/<YYYY-MM-DD>/ (needs RUNS_TOKEN)
# Environment:
#   RUNS_TOKEN   push: a token with Contents read and write on azsupport/azsupport
#                (the secret of tools/runs-report.sh)
#   RUNS_REMOTE  push: the repository to commit to instead (a path, for a test)
# What a fetch writes into <out dir>:
#   pkg-vulnerabilities         the list of pkgsrc, uncompressed (its PGP signature
#                               is kept in the file, not checked here)
#   files/<host>/<path>         a file of an <item>; for an archive with members,
#                               files/<host>/<path>.d/<member>
#   report.md                   what was fetched, its size and SHA-256, what failed
#                               and why (the summary of the run; a push puts it at
#                               distro/pkgsrc/<date>/<run id>.md)
# The exit status of a fetch is 1 when an item failed: the rest is still written,
# and report.md says what failed.

set -u
set -f
cmd="${1:-}"
[ $# -gt 0 ] && shift
usage() {
    echo "usage: sh tools/pkgsrc-fetch.sh fetch <out dir> [<url>[=<sha256>][::<member>,...]]..." >&2
    echo "       sh tools/pkgsrc-fetch.sh push <out dir>" >&2
    exit 2
}
w="$(mktemp -d)"
trap 'rm -rf "$w"' EXIT
MAXSIZE=20971520

# ---------------------------------------------------------------------------- push
if [ "$cmd" = push ]; then
    [ $# -eq 1 ] || usage
    src="$(cd "$1" && pwd)" || exit 1
    remote="${RUNS_REMOTE:-}"
    if [ -z "$remote" ]; then
        if [ -z "${RUNS_TOKEN:-}" ]; then
            echo "::warning title=pkgsrc fetch::RUNS_TOKEN is not set: nothing committed to azsupport/azsupport (branch runs)"
            exit 0
        fi
        remote="https://x-access-token:${RUNS_TOKEN}@github.com/azsupport/azsupport.git"
    fi
    hide() { sed 's#x-access-token:[^@]*@#x-access-token:***@#g'; }
    day="$(date -u +%Y-%m-%d)"
    run="${GITHUB_RUN_ID:-0}"
    r="$w/runs"
    if ! git clone -q --depth 1 --branch runs --single-branch "$remote" "$r" 2>"$w/err"; then
        echo "::error title=pkgsrc fetch::clone of azsupport/azsupport (runs) failed: $(hide < "$w/err" | tail -n 2 | tr '\n' ' ')"
        exit 1
    fi
    # the identity of the commit and of a rebase on a refused push
    git -C "$r" config user.name 'github-actions[bot]'
    git -C "$r" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
    base="distro/pkgsrc/$day"
    mkdir -p "$r/$base"
    # the files of this run in the place of those of an earlier run of the day
    if [ -f "$src/pkg-vulnerabilities" ]; then
        cp "$src/pkg-vulnerabilities" "$r/$base/pkg-vulnerabilities"
    fi
    if [ -d "$src/files" ]; then
        (cd "$src" && find files -type f) | while IFS= read -r f; do
            mkdir -p "$r/$base/$(dirname "$f")"
            cp "$src/$f" "$r/$base/$f"
        done
    fi
    {
        echo "# pkgsrc-fetch — $day"
        echo
        echo "- run: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-azsupport/php-src}/actions/runs/$run (attempt ${GITHUB_RUN_ATTEMPT:-1})"
        echo "- commit: ${GITHUB_SHA:-?} $(git log -1 --format=%s 2>/dev/null)"
        echo "- written: $(date -u '+%Y-%m-%d %H:%M UTC')"
        echo "- files: $base/pkg-vulnerabilities, $base/files/<host>/<path>"
        echo
        if [ -s "$src/report.md" ]; then cat "$src/report.md"; else echo "(no report: the fetch wrote none)"; fi
    } > "$r/$base/$run.md"
    git -C "$r" add -A "$base"
    git -C "$r" commit -q -m "pkgsrc-fetch: run $run" || { echo "::error title=pkgsrc fetch::commit failed"; exit 1; }
    # other runs push into runs too: on a refused push, rebase and again
    i=0
    while [ $i -lt 6 ]; do
        i=$((i + 1))
        if git -C "$r" push -q origin HEAD:runs 2>"$w/err"; then
            echo "pkgsrc fetch: $base/$run.md"
            exit 0
        fi
        sleep $((i * 5))
        git -C "$r" pull -q --rebase origin runs 2>>"$w/err" || git -C "$r" rebase --abort 2>/dev/null
    done
    echo "::error title=pkgsrc fetch::push to azsupport/azsupport (runs) failed: $(hide < "$w/err" | tail -n 3 | tr '\n' ' ')"
    exit 1
fi

# --------------------------------------------------------------------------- fetch
if [ "$cmd" != fetch ] || [ $# -lt 1 ]; then
    usage
fi
out="$1"
shift
mkdir -p "$out" && out="$(cd "$out" && pwd)" || exit 1
rep="$out/report.md"
: > "$rep"
say() { printf '%s\n' "$*" >> "$rep"; }
failed=0

# get <url> <file>: https only, redirects followed, at most MAXSIZE bytes
get() {
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 5 \
        --connect-timeout 30 --max-time 600 --max-filesize "$MAXSIZE" \
        -A 'pkgsrc-fetch (azsupport/php-src)' -o "$2" "$1" 2>"$w/err"
}

sha() { sha256sum "$1" | cut -d' ' -f1; }

# the vulnerability list of pkgsrc
say "## pkg-vulnerabilities"
say
got=''
for u in https://cdn.netbsd.org/pub/NetBSD/packages/vulns/pkg-vulnerabilities.gz \
         https://ftp.netbsd.org/pub/NetBSD/packages/vulns/pkg-vulnerabilities.gz; do
    if get "$u" "$w/pv.gz" && gzip -dc "$w/pv.gz" > "$out/pkg-vulnerabilities" 2>"$w/err"; then
        got="$u"
        break
    fi
    say "- $u: $(tail -n 1 "$w/err")"
done
if [ -n "$got" ]; then
    # shellcheck disable=SC2016
    stamp="$(grep -m 1 -E '^# \$NetBSD' "$out/pkg-vulnerabilities" || true)"
    signed=no
    grep -q -- '-----BEGIN PGP SIGNATURE-----' "$out/pkg-vulnerabilities" && signed=yes
    say "- $got: $(wc -l < "$out/pkg-vulnerabilities") lines, SHA-256 of the .gz $(sha "$w/pv.gz"), PGP signature block: $signed (not checked)"
    [ -n "$stamp" ] && say "- version line: \`$stamp\`"
else
    rm -f "$out/pkg-vulnerabilities"
    say "- not fetched"
    failed=1
fi
say

[ $# -gt 0 ] && say "## Files" && say
for item in "$@"; do
    spec="${item%%::*}"
    members=''
    case "$item" in *::*) members="${item#*::}" ;; esac
    url="${spec%%=*}"
    want=''
    case "$spec" in *=*) want="${spec#*=}" ;; esac
    case "$url" in
        https://*) ;;
        *) say "- \`$item\`: not an https URL, skipped"; failed=1; continue ;;
    esac
    rel="${url#https://}"
    rel="${rel%%\?*}"
    case "$rel" in
        *..*) say "- \`$item\`: a path with \"..\", skipped"; failed=1; continue ;;
    esac
    host="${rel%%/*}"
    path="${rel#*/}"
    if ! get "$url" "$w/file"; then
        say "- $url: $(tail -n 1 "$w/err")"
        failed=1
        continue
    fi
    have="$(sha "$w/file")"
    if [ -n "$want" ] && [ "$have" != "$want" ]; then
        say "- $url: SHA-256 $have, expected $want: not kept"
        failed=1
        continue
    fi
    check="not checked"
    [ -n "$want" ] && check="checked"
    if [ -z "$members" ]; then
        mkdir -p "$out/files/$host/$(dirname "$path")"
        cp "$w/file" "$out/files/$host/$path"
        say "- $url: $(wc -c < "$w/file") bytes, SHA-256 $have ($check) → files/$host/$path"
        continue
    fi
    x="$w/x"
    rm -rf "$x"
    mkdir -p "$x"
    case "$path" in
        *.zip) unzip -q "$w/file" -d "$x" 2>"$w/err" ;;
        *) tar -xf "$w/file" -C "$x" 2>"$w/err" ;;
    esac || { say "- $url: not unpacked: $(tail -n 1 "$w/err")"; failed=1; continue; }
    say "- $url: SHA-256 $have ($check), members:"
    for m in $(printf '%s' "$members" | tr ',' ' '); do
        case "$m" in
            */../*|../*|*/..) say "  - \`$m\`: a path with \"..\", skipped"; failed=1; continue ;;
        esac
        found=''
        case "$m" in
            '*/'*)
                set +f
                for d in "$x"/*/; do [ -f "$d${m#\*/}" ] && found="$d${m#\*/}" && break; done
                set -f
                ;;
            *) [ -f "$x/$m" ] && found="$x/$m" ;;
        esac
        if [ -z "$found" ]; then
            say "  - \`$m\`: not in the archive"
            failed=1
            continue
        fi
        dest="$out/files/$host/$path.d/${found#"$x"/}"
        mkdir -p "$(dirname "$dest")"
        cp "$found" "$dest"
        say "  - \`${found#"$x"/}\` → files/$host/$path.d/${found#"$x"/}"
    done
done

exit "$failed"
