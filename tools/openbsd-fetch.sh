#!/bin/sh
# openbsd-fetch.sh - the -stable branches OPENBSD_x_y of the OpenBSD ports tree,
# which the GitHub mirror openbsd/ports lacks (it carries the HEAD of the CVS tree
# only): the security fixes OpenBSD merges into the ports of its releases, often to
# older versions than those of its HEAD. Read over anoncvs (ssh) from a mirror of
# https://www.openbsd.org/anoncvs.html whose host key matches a fingerprint
# published on that page. Workflow: .github/workflows/openbsd-fetch.yml.
#
# Usage:
#   sh tools/openbsd-fetch.sh fetch <out dir> <port dir>...
#       <port dir>: a directory of the ports tree, as security/sudo, lang/php (with
#       its subdirectories) or lang/php/7.4 (also one removed from the tree)
#   sh tools/openbsd-fetch.sh push <out dir>
#       commit what a fetch wrote into the branch runs of azsupport/azsupport,
#       distro/openbsd/<YYYY-MM-DD>/ (needs RUNS_TOKEN)
# Environment:
#   BRANCHES    fetch: the branches to take, separated by spaces (OPENBSD_7_8 ...);
#               empty: every OPENBSD_x_y branch with revisions in the directory,
#               and the two newest branches of the tree (the supported releases)
#               in any case
#   CVSROOTS    fetch: anoncvs roots to try in turn instead of those of
#               anoncvs.html (anoncvs@anoncvs.example.org:/cvs ...); their host
#               keys are taken on first use
#   RUNS_TOKEN  push: a token with Contents read and write on azsupport/azsupport
#               (the secret of tools/runs-report.sh)
#   RUNS_REMOTE push: the repository to commit to instead (a path, for a test)
# What a fetch writes into <out dir>:
#   <branch>/<port dir>/             the files of the directory on the branch
#                                    (cvs export -r <branch>): Makefile, distinfo,
#                                    patches/, files/, pkg/
#   <branch>/<port dir>/rlog.txt     its revisions on the branch: the commits
#                                    merged into it, with date, author and message
#                                    (cvs rlog -N -r<branch>, the files with
#                                    revisions on the branch only)
#   <branch>/<port dir>/branch.diff  the branch against the release it started
#                                    from (cvs rdiff -u -r <branch>_BASE -r <branch>)
#   report.md                        the mirror and its host key, the branches of
#                                    each directory with their revisions, what was
#                                    taken and what failed (the summary of the run;
#                                    a push puts it at distro/openbsd/<date>/<run id>.md)
#   taken.txt                        "<branch> <port dir>" per directory taken
# The exit status of a fetch is 1 when a directory or a branch failed: the rest is
# still written, and report.md says what failed and why.

set -u
set -f
cmd="${1:-}"
[ $# -gt 0 ] && shift
usage() {
    echo "usage: sh tools/openbsd-fetch.sh fetch <out dir> <port dir>..." >&2
    echo "       sh tools/openbsd-fetch.sh push <out dir>" >&2
    exit 2
}
w="$(mktemp -d)"
master_stop() { [ -S "$w/cm" ] && ssh -o ControlPath="$w/cm" -O exit anoncvs 2>/dev/null; return 0; }
trap 'master_stop; rm -rf "$w"' EXIT

# ---------------------------------------------------------------------------- push
if [ "$cmd" = push ]; then
    [ $# -eq 1 ] || usage
    src="$(cd "$1" && pwd)" || exit 1
    remote="${RUNS_REMOTE:-}"
    if [ -z "$remote" ]; then
        if [ -z "${RUNS_TOKEN:-}" ]; then
            echo "::warning title=openbsd fetch::RUNS_TOKEN is not set: nothing committed to azsupport/azsupport (branch runs)"
            exit 0
        fi
        remote="https://x-access-token:${RUNS_TOKEN}@github.com/azsupport/azsupport.git"
    fi
    hide() { sed 's#x-access-token:[^@]*@#x-access-token:***@#g'; }
    day="$(date -u +%Y-%m-%d)"
    run="${GITHUB_RUN_ID:-0}"
    r="$w/runs"
    if ! git clone -q --depth 1 --branch runs --single-branch "$remote" "$r" 2>"$w/err"; then
        echo "::error title=openbsd fetch::clone of azsupport/azsupport (runs) failed: $(hide < "$w/err" | tail -n 2 | tr '\n' ' ')"
        exit 1
    fi
    # the identity of the commit and of a rebase onto the pushes of other runs
    git -C "$r" config user.name 'github-actions[bot]'
    git -C "$r" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
    base="distro/openbsd/$day"
    mkdir -p "$r/$base"
    # each directory of each branch in the place of that of an earlier run of the day
    if [ -f "$src/taken.txt" ]; then
        while read -r b d; do
            if [ -z "$b" ] || [ -z "$d" ] || [ ! -d "$src/$b/$d" ]; then
                continue
            fi
            rm -rf "${r:?}/$base/$b/$d"
            mkdir -p "$r/$base/$b/$(dirname "$d")"
            cp -R "$src/$b/$d" "$r/$base/$b/$d"
        done < "$src/taken.txt"
    fi
    {
        echo "# openbsd-fetch — $day"
        echo
        echo "- run: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-azsupport/php-src}/actions/runs/$run (attempt ${GITHUB_RUN_ATTEMPT:-1})"
        echo "- commit: ${GITHUB_SHA:-?} $(git log -1 --format=%s 2>/dev/null)"
        echo "- written: $(date -u '+%Y-%m-%d %H:%M UTC')"
        echo "- files: $base/<branch>/<port dir>/ (the directory on the branch, rlog.txt, branch.diff)"
        echo
        if [ -s "$src/report.md" ]; then cat "$src/report.md"; else echo "(no report: the fetch wrote none)"; fi
    } > "$r/$base/$run.md"
    git -C "$r" add -A "$base"
    git -C "$r" commit -q -m "openbsd-fetch: run $run" || { echo "::error title=openbsd fetch::commit failed"; exit 1; }
    # other runs push into runs too: on a refused push, rebase and again
    i=0
    : > "$w/err"
    while [ $i -lt 6 ]; do
        i=$((i + 1))
        if git -C "$r" push -q origin HEAD:runs 2>>"$w/err"; then
            echo "openbsd fetch: $base/$run.md"
            exit 0
        fi
        sleep $((i * 5))
        git -C "$r" pull -q --rebase origin runs 2>>"$w/err" || git -C "$r" rebase --abort 2>/dev/null
    done
    echo "::error title=openbsd fetch::push to azsupport/azsupport (runs) failed: $(hide < "$w/err" | tail -n 3 | tr '\n' ' ')"
    exit 1
fi

# --------------------------------------------------------------------------- fetch
if [ "$cmd" != fetch ] || [ $# -lt 2 ]; then
    usage
fi
out="$1"
shift
mkdir -p "$out" && out="$(cd "$out" && pwd)" || exit 1
rep="$out/report.md"
: > "$rep"
: > "$out/taken.txt"
say() { printf '%s\n' "$*" >> "$rep"; }
# progress into the log of the job
note() { printf '%s openbsd-fetch: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
failed=0

command -v cvs > /dev/null || { echo "openbsd-fetch: cvs is not installed" >&2; exit 1; }

# ssh for cvs: the host keys of $w/known_hosts only; through the connection of the
# master (started below) when there is one
# shellcheck disable=SC1003,SC2016
{
    echo '#!/bin/sh'
    echo 'exec ssh -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \'
    echo "    -o UserKnownHostsFile=\"$w/known_hosts\" -o GlobalKnownHostsFile=/dev/null \\"
    echo '    -o StrictHostKeyChecking="${OBF_STRICT:-yes}" \'
    echo "    -o ControlMaster=\"\${OBF_MASTER:-no}\" -o ControlPath=\"$w/cm\" \"\$@\""
} > "$w/ssh"
chmod +x "$w/ssh"
CVS_RSH="$w/ssh"
export CVS_RSH
: > "$w/known_hosts"
root=''

# cvsq <file> <cvs command> <arguments>: the output into <file>, its errors into
# $w/cvserr; up to $CVSQ_TRIES tries (3) of at most $CVSQ_TIME seconds (900) each
# when the connection fails
cvsq() {
    f="$1"
    shift
    n=0
    while :; do
        n=$((n + 1))
        rc=0
        note "cvs $* (try $n)"
        timeout "${CVSQ_TIME:-900}" cvs -q -z3 -d ":ext:$root" "$@" > "$f" 2>"$w/cvserr" || rc=$?
        [ $rc -eq 0 ] && return 0
        # rdiff may end in 1 when it found differences
        [ "$1" = rdiff ] && [ -s "$f" ] && return 0
        # a missing tag, revision or directory, or a refused option, is an answer,
        # not a failure of the connection
        if grep -q -E 'no revision|no such tag|cannot find module|could not find|there is no|[Uu]sage:|--help' "$w/cvserr"; then
            return $rc
        fi
        note "cvs $1: exit $rc: $(tail -n 1 "$w/cvserr")"
        [ $n -lt "${CVSQ_TRIES:-3}" ] || return $rc
        sleep $((n * 15))
    done
}

# the mirrors and the fingerprints of their host keys
roots="${CVSROOTS:-}"
verify=yes
: > "$w/fps"
if [ -z "$roots" ]; then
    if curl -fsSL --retry 3 --max-time 60 https://www.openbsd.org/anoncvs.html > "$w/anoncvs.html" 2>"$w/err"; then
        roots="$(grep -o -E 'anoncvs@[A-Za-z0-9.-]+:/[A-Za-z0-9/_.-]+' "$w/anoncvs.html" | awk '!seen[$0]++' | tr '\n' ' ')"
        grep -o -E 'SHA256:[A-Za-z0-9+/]{43}' "$w/anoncvs.html" | sort -u > "$w/fps"
    else
        say "- anoncvs.html could not be read: $(tail -n 1 "$w/err")"
    fi
    if [ -z "$roots" ]; then
        roots="anoncvs@anoncvs.spacehopper.org:/cvs anoncvs@anoncvs.ca:/cvs anoncvs@anoncvs1.usa.openbsd.org:/cvs anoncvs@anoncvs.au.openbsd.org:/cvs anoncvs@anoncvs.fr.openbsd.org:/cvs"
        say "- no mirror found on anoncvs.html: the built-in list"
    fi
fi
[ -s "$w/fps" ] || verify=no

# try_mirrors yes|no: the first mirror that answers (of the first 12); with yes
# only one whose host key has a fingerprint of anoncvs.html
keynote=''
try_mirrors() {
    tried=0
    for cand in $roots; do
        tried=$((tried + 1))
        [ $tried -le 12 ] || break
        host="${cand#*@}"
        host="${host%%:*}"
        : > "$w/known_hosts"
        keynote=''
        note "mirror $cand (verify: $1)"
        timeout 30 ssh-keyscan -T 15 -t ed25519,ecdsa,rsa "$host" 2>/dev/null | grep -v '^#' > "$w/keys"
        if [ ! -s "$w/keys" ]; then
            say "- \`$cand\`: no answer on port 22, skipped"
            continue
        fi
        if [ "$1" = yes ]; then
            OBF_STRICT=yes
            while IFS= read -r line; do
                printf '%s\n' "$line" > "$w/one"
                fp="$(ssh-keygen -l -f "$w/one" 2>/dev/null | awk '{ print $2 }')"
                if [ -n "$fp" ] && grep -q -x -F "$fp" "$w/fps"; then
                    printf '%s\n' "$line" >> "$w/known_hosts"
                    keynote="$keynote $(ssh-keygen -l -f "$w/one" | awk '{ print $NF " " $2 }')"
                fi
            done < "$w/keys"
            if [ ! -s "$w/known_hosts" ]; then
                say "- \`$cand\`: no host key with a fingerprint of anoncvs.html, skipped"
                continue
            fi
        else
            OBF_STRICT=accept-new
        fi
        export OBF_STRICT
        root="$cand"
        # one ssh connection for all the cvs commands of the run
        OBF_MASTER=yes timeout 60 "$w/ssh" -f -N "${root%%:*}" < /dev/null > /dev/null 2>&1 || true
        # one try, three minutes at most: the next mirror rather than a slow one
        CVSQ_TRIES=1
        CVSQ_TIME=180
        ok=no
        cvsq "$w/top" rlog -h ports/Makefile && [ -s "$w/top" ] && ok=yes
        unset CVSQ_TRIES CVSQ_TIME
        if [ $ok = yes ]; then
            note "mirror $cand answers"
            return 0
        fi
        say "- \`$cand\`: no answer ($(tail -n 1 "$w/cvserr" 2>/dev/null | tr '|' '/')), skipped"
        master_stop
        root=''
    done
    return 1
}
if [ "$verify" = yes ] && try_mirrors yes; then
    say "- mirror: \`$root\`, host key$keynote, as published on https://www.openbsd.org/anoncvs.html"
elif try_mirrors no; then
    say "- mirror: \`$root\`, host key taken on first use (**not verified** against anoncvs.html)"
else
    say "- **no anoncvs mirror answered**: nothing fetched"
    exit 1
fi

# OPENBSD_x_y branch tags of an rlog (magic branch numbers a.b.0.n), oldest first
vsort() { awk -F_ '{ printf "%d %d %s\n", $2, $3, $0 }' | sort -k1,1n -k2,2n | cut -d' ' -f3-; }
newest="$(sed -n 's/^[[:space:]]*\(OPENBSD_[0-9]*_[0-9]*\): [0-9.]*\.0\.[0-9]*$/\1/p' "$w/top" | sort -u | vsort |
    tail -n 2 | tr '\n' ' ')"
say "- the two newest branches of the tree: $newest"
if [ -n "${BRANCHES:-}" ]; then
    for b in $BRANCHES; do
        case "$b" in
            OPENBSD_[0-9]*_[0-9]*) ;;
            *) say "- \`$b\`: not a branch OPENBSD_x_y, left out" ;;
        esac
    done
    say "- branches asked: $BRANCHES"
else
    say "- branches: every OPENBSD_x_y branch with revisions in a directory, and the two newest"
fi
say ""
say "| Directory | Branches with revisions (revisions) | Taken | Not taken, failures |"
say "|---|---|---|---|"

# the OPENBSD_x_y branch tags of the files of an rlog: "<tag> <revisions on the
# branch>" (a.b.0.n is the branch a.b.n, whose revisions are a.b.n.1, a.b.n.2 ...)
cat > "$w/branches.awk" <<'EOF'
/^RCS file: / { nt = 0; split("", tn); split("", tb); insym = 0; next }
/^symbolic names:/ { insym = 1; next }
insym && /^[ \t]/ {
    line = $0
    sub(/^[ \t]+/, "", line)
    i = index(line, ": ")
    if (i == 0) next
    name = substr(line, 1, i - 1)
    rev = substr(line, i + 2)
    if (name ~ /^OPENBSD_[0-9]+_[0-9]+$/ && rev ~ /\.0\.[0-9]+$/) {
        n = split(rev, p, ".")
        br = ""
        for (k = 1; k <= n - 2; k++) br = br p[k] "."
        br = br p[n] "."
        nt++
        tn[nt] = name
        tb[nt] = br
        seen[name] = 1
    }
    next
}
insym { insym = 0 }
prev == "----------------------------" && /^revision [0-9.]+/ {
    for (k = 1; k <= nt; k++)
        if (index($2, tb[k]) == 1 && length($2) > length(tb[k])) cnt[tn[k]]++
}
{ prev = $0 }
END { for (t in seen) print t, cnt[t] + 0 }
EOF

for d in "$@"; do
    d="${d#ports/}"
    d="${d%/}"
    note "directory $d"
    case "$d" in
        '' | /* | *..* | *[!A-Za-z0-9._/+-]*)
            say "| \`$d\` | | | not a directory of the ports tree |"
            failed=1
            continue
            ;;
    esac
    if ! cvsq "$w/full" rlog "ports/$d" || ! grep -q '^RCS file: ' "$w/full"; then
        say "| \`$d\` | | | rlog failed: $(tail -n 1 "$w/cvserr" | tr '|' '/') |"
        failed=1
        continue
    fi
    awk -f "$w/branches.awk" "$w/full" | vsort > "$w/br"
    withrev="$(awk '$2 > 0 { printf "%s (%d) ", $1, $2 }' "$w/br")"
    if [ -n "${BRANCHES:-}" ]; then
        sel="$BRANCHES"
    else
        # shellcheck disable=SC2086
        sel="$({ awk '$2 > 0 { print $1 }' "$w/br"; printf '%s\n' $newest; } | sort -u | vsort | tr '\n' ' ')"
    fi
    taken=''
    notes=''
    for b in $sel; do
        case "$b" in OPENBSD_[0-9]*_[0-9]*) ;; *) continue ;; esac
        dest="$out/$b/$d"
        rm -rf "$dest"
        mkdir -p "$(dirname "$dest")"
        rc=0
        (cd "$(dirname "$dest")" && cvsq "$w/export.out" export -r "$b" -d "$(basename "$dest")" "ports/$d") || rc=$?
        if [ -d "$dest" ] && [ -z "$(find "$dest" -type f | head -n 1)" ]; then
            rm -rf "$dest"
        fi
        if [ ! -d "$dest" ]; then
            if [ $rc -eq 0 ] || grep -q -E 'no revision|no such tag|cannot find module|could not find' "$w/cvserr"; then
                notes="$notes $b: not on the branch;"
            else
                notes="$notes $b: export failed ($(tail -n 1 "$w/cvserr" | tr '|' '/'));"
                failed=1
            fi
            continue
        fi
        # the cvs of the OpenBSD servers knows no rlog -S: the files without
        # revisions on the branch are left out here
        rc=0
        cvsq "$w/rlog" rlog -N -r"$b" "ports/$d" || rc=$?
        awk '
            { blk = blk $0 "\n" }
            /^total revisions: .*selected revisions: [0-9]+/ { n = $NF + 0 }
            /^=============================================================================$/ {
                if (n > 0) printf "%s", blk
                blk = ""; n = 0
            }' "$w/rlog" > "$dest/rlog.txt"
        if [ $rc -ne 0 ] && [ ! -s "$dest/rlog.txt" ] && ! grep -q 'no revision' "$w/cvserr"; then
            notes="$notes $b: rlog failed ($(tail -n 1 "$w/cvserr" | tr '|' '/'));"
            printf '(rlog failed: %s)\n' "$(tail -n 1 "$w/cvserr")" > "$dest/rlog.txt"
            failed=1
        elif [ ! -s "$dest/rlog.txt" ]; then
            printf '(no revisions of ports/%s on %s: the directory as the release had it)\n' "$d" "$b" > "$dest/rlog.txt"
        fi
        rc=0
        cvsq "$dest/branch.diff" rdiff -u -r "${b}_BASE" -r "$b" "ports/$d" || rc=$?
        if [ ! -s "$dest/branch.diff" ]; then
            if [ $rc -eq 0 ]; then
                printf '(no differences between %s_BASE and %s)\n' "$b" "$b" > "$dest/branch.diff"
            else
                printf '(no diff: %s)\n' "$(tail -n 1 "$w/cvserr")" > "$dest/branch.diff"
            fi
        fi
        taken="$taken $b"
        printf '%s %s\n' "$b" "$d" >> "$out/taken.txt"
    done
    say "| \`$d\` | ${withrev:-none} | ${taken:-none} | ${notes:-} |"
done

exit "$failed"
