#!/bin/sh
# slackware-fetch.sh - what Slackware builds its packages with, for some of them:
# the files of their source directories (the SlackBuild, the patches, the configs;
# not the source tarballs) in source/ of the trees slackware64-current,
# slackware64-15.0 and slackware64-14.2, the security updates of the releases in
# patches/source/, and extra/, testing/ and pasture/ of each tree; with the
# ChangeLog.txt of each tree (the advisories, with their CVE ids). Slackware's
# mirrors are closed to the sandbox of Claude Code, GitHub is not: this runs on a
# runner of GitHub Actions (workflow .github/workflows/slackware-fetch.yml).
#
# Usage:
#   sh tools/slackware-fetch.sh fetch <out dir> <package>...
#       <package>: the name of a source directory of Slackware (php, httpd,
#       infozip, imagemagick ...), as the last part of its path, case ignored;
#       "*" matches any characters ("php*": php, php80 ...)
#   sh tools/slackware-fetch.sh push <out dir>
#       commit what a fetch wrote into the branch runs of azsupport/azsupport,
#       distro/slackware/<YYYY-MM-DD>/ (needs RUNS_TOKEN)
# Environment:
#   TREES       fetch: the trees, separated by spaces (default
#               "slackware64-current slackware64-15.0 slackware64-14.2")
#   MIRRORS     fetch: the mirrors to try in turn, the URLs of the directories
#               that hold the trees (default: slackware.uk, mirrors.kernel.org,
#               ftp.osuosl.org)
#   MAXSIZE     fetch: a file larger than this many bytes is listed, not fetched
#               (default 2000000: the source tarballs stay out)
#   RUNS_TOKEN  push: a token with Contents read and write on azsupport/azsupport
#               (the secret of tools/runs-report.sh)
#   RUNS_REMOTE push: the repository to commit to instead (a path, for a test)
# What a fetch writes into <out dir>:
#   <tree>/<path in the tree>        the files fetched, at their paths in the tree
#                                    (source/n/php/php.SlackBuild ...)
#   <tree>/ChangeLog.txt             the ChangeLog of the tree
#   <tree>/dirs.txt                  every source directory of the tree, with its
#                                    files (name size date): the names to ask for
#   <tree>/skipped.txt               the files of the directories asked for that
#                                    were not fetched (larger than MAXSIZE)
#   report.md                        per tree: the mirror, the signature of its
#                                    CHECKSUMS.md5 (gpg, the key of Slackware), the
#                                    directories of each package and their files,
#                                    what is not in the tree and what failed (the
#                                    summary of the run; a push puts it at
#                                    distro/slackware/<date>/<run id>.md)
# Every file fetched is checked against CHECKSUMS.md5 of its tree, whose signature
# is checked against the key of the Slackware Linux Project
# <security@slackware.com> (fingerprint below, as https://www.slackware.com/gpg-key
# publishes it). The exit status of a fetch is 1 when a tree or a file failed: the
# rest is still written, and report.md says what failed and why.

set -u
set -f
cmd="${1:-}"
[ $# -gt 0 ] && shift
usage() {
    echo "usage: sh tools/slackware-fetch.sh fetch <out dir> <package>..." >&2
    echo "       sh tools/slackware-fetch.sh push <out dir>" >&2
    exit 2
}
w="$(mktemp -d)"
trap 'rm -rf "$w"' EXIT

# the key that signs the CHECKSUMS.md5 of every tree of Slackware
SLACKWARE_FPR=EC5649DA401E22ABFA6736EF6A4463C040102233

# ---------------------------------------------------------------------------- push
if [ "$cmd" = push ]; then
    [ $# -eq 1 ] || usage
    src="$(cd "$1" && pwd)" || exit 1
    remote="${RUNS_REMOTE:-}"
    if [ -z "$remote" ]; then
        if [ -z "${RUNS_TOKEN:-}" ]; then
            echo "::warning title=slackware fetch::RUNS_TOKEN is not set: nothing committed to azsupport/azsupport (branch runs)"
            exit 0
        fi
        remote="https://x-access-token:${RUNS_TOKEN}@github.com/azsupport/azsupport.git"
    fi
    hide() { sed 's#x-access-token:[^@]*@#x-access-token:***@#g'; }
    day="$(date -u +%Y-%m-%d)"
    run="${GITHUB_RUN_ID:-0}"
    base="distro/slackware/$day"
    r="$w/runs"
    if ! git clone -q --depth 1 --filter=blob:none --sparse --branch runs --single-branch "$remote" "$r" 2>"$w/err" ||
        ! git -C "$r" sparse-checkout set "$base" 2>>"$w/err"; then
        echo "::error title=slackware fetch::clone of azsupport/azsupport (runs) failed: $(hide < "$w/err" | tail -n 2 | tr '\n' ' ')"
        exit 1
    fi
    mkdir -p "$r/$base"
    # the files of each tree added to those of an earlier run of the day (no glob:
    # set -f is on)
    for t in $(cd "$src" && find . -mindepth 1 -maxdepth 1 -type d | sed 's#^\./##'); do
        mkdir -p "$r/$base/$t"
        cp -R "$src/$t/." "$r/$base/$t/"
    done
    {
        echo "# slackware-fetch — $day"
        echo
        echo "- run: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-azsupport/php-src}/actions/runs/$run (attempt ${GITHUB_RUN_ATTEMPT:-1})"
        echo "- commit: ${GITHUB_SHA:-?} $(git log -1 --format=%s 2>/dev/null)"
        echo "- written: $(date -u '+%Y-%m-%d %H:%M UTC')"
        echo "- files: $base/<tree>/<path in the tree> (ChangeLog.txt, dirs.txt, skipped.txt of each tree)"
        echo
        if [ -s "$src/report.md" ]; then cat "$src/report.md"; else echo "(no report: the fetch wrote none)"; fi
    } > "$r/$base/$run.md"
    git -C "$r" add -A "$base"
    git -C "$r" -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
        commit -q -m "slackware-fetch: run $run" || { echo "::error title=slackware fetch::commit failed"; exit 1; }
    # other runs push into runs too: on a refused push, rebase and again
    i=0
    while [ $i -lt 6 ]; do
        i=$((i + 1))
        if git -C "$r" push -q origin HEAD:runs 2>"$w/err"; then
            echo "slackware fetch: $base/$run.md"
            exit 0
        fi
        sleep $((i * 5))
        git -C "$r" pull -q --rebase origin runs 2>>"$w/err" || git -C "$r" rebase --abort 2>/dev/null
    done
    echo "::error title=slackware fetch::push to azsupport/azsupport (runs) failed: $(hide < "$w/err" | tail -n 3 | tr '\n' ' ')"
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
say() { printf '%s\n' "$*" >> "$rep"; }
failed=0
trees="${TREES:-slackware64-current slackware64-15.0 slackware64-14.2}"
mirrors="${MIRRORS:-https://slackware.uk/slackware https://mirrors.kernel.org/slackware https://ftp.osuosl.org/pub/slackware}"
maxsize="${MAXSIZE:-2000000}"

# the names asked for as one regular expression of awk on the last part of a path
pat=''
for p in "$@"; do
    case "$p" in
        '' | */* | *[!A-Za-z0-9._+*-]*)
            say "- \`$p\`: not a name of a source directory, left out"
            failed=1
            continue
            ;;
    esac
    # shellcheck disable=SC2001
    re="$(printf '%s' "$p" | tr 'A-Z' 'a-z' | sed 's/[.+]/\\&/g; s/\*/.*/g')"
    pat="$pat${pat:+|}$re"
done
[ -n "$pat" ] || { say "- no package to fetch"; exit 1; }
printf '%s\n' "$@" | tr 'A-Z' 'a-z' > "$w/asked"

get() {
    curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 30 --max-time 600 -o "$2" "$1" 2>"$w/curlerr"
}

gpg_home="$w/gnupg"
mkdir -p "$gpg_home"
chmod 700 "$gpg_home"

for tree in $trees; do
    case "$tree" in
        '' | *[!A-Za-z0-9._-]*) say "- tree \`$tree\`: not a name of a tree, left out"; failed=1; continue ;;
    esac
    say "## $tree"
    say ""
    tdir="$out/$tree"
    mkdir -p "$tdir"
    mirror=''
    for m in $mirrors; do
        if get "$m/$tree/FILELIST.TXT" "$w/FILELIST.TXT" && get "$m/$tree/CHECKSUMS.md5" "$w/CHECKSUMS.md5"; then
            mirror="$m"
            break
        fi
        say "- mirror $m: no FILELIST.TXT or CHECKSUMS.md5 ($(tail -n 1 "$w/curlerr"))"
    done
    if [ -z "$mirror" ]; then
        say "- **no mirror has the tree**: nothing fetched"
        say ""
        failed=1
        continue
    fi
    say "- mirror: $mirror/$tree/ ($(sed -n '1p' "$w/FILELIST.TXT"))"
    if [ ! -s "$w/GPG-KEY" ] && get "$mirror/$tree/GPG-KEY" "$w/GPG-KEY"; then
        gpg --homedir "$gpg_home" --batch --quiet --import "$w/GPG-KEY" 2>/dev/null
    fi

    # checked <prefix>: the signature of <prefix>CHECKSUMS.md5 (in $w/sums), made
    # by the key of Slackware?; its lines go into $w/md5 with the paths of the tree
    : > "$w/md5"
    checked() {
        if ! get "$mirror/$tree/${1}CHECKSUMS.md5.asc" "$w/sums.asc"; then
            sig="**${1}CHECKSUMS.md5.asc missing** ($(tail -n 1 "$w/curlerr")): its files not checked"
            failed=1
            return 1
        fi
        if gpg --homedir "$gpg_home" --batch --status-fd 1 --verify "$w/sums.asc" "$w/sums" \
            > "$w/gpgstatus" 2>/dev/null; then
            fpr="$(awk '$2 == "VALIDSIG" { print $NF; exit }' "$w/gpgstatus")"
            if [ "$fpr" != "$SLACKWARE_FPR" ]; then
                sig="**good, but by the key $fpr, not that of Slackware ($SLACKWARE_FPR)**: its files not checked"
                failed=1
                return 1
            fi
            sig="good, key $fpr (Slackware Linux Project)"
            awk -v pre="$1" '$2 ~ /^\.\// { p = substr($2, 3); print $1, pre p }' "$w/sums" >> "$w/md5"
            return 0
        fi
        sig="**bad or missing** ($(awk '{ print $2 }' "$w/gpgstatus" | tr '\n' ' ')): its files not checked"
        failed=1
        return 1
    }
    cp "$w/CHECKSUMS.md5" "$w/sums"
    checked ''
    say "- signature of CHECKSUMS.md5: $sig"
    if get "$mirror/$tree/ChangeLog.txt" "$tdir/ChangeLog.txt"; then
        say "- ChangeLog.txt: $(wc -l < "$tdir/ChangeLog.txt") lines"
    else
        say "- **ChangeLog.txt failed** ($(tail -n 1 "$w/curlerr"))"
        failed=1
    fi

    # the files of the source directories: "<dir> <file path> <size> <date>"; a
    # source directory is source/<series>/<name> or <area>/source/<name>
    # (patches/source/<name>, extra/source/<name>, testing/, pasture/)
    lsfiles() {
        awk -v pre="$1" '
            NF >= 8 && substr($1, 1, 1) == "-" {
                p = $8
                sub(/^\.\//, "", p)
                p = pre p
                n = split(p, c, "/")
                d = ""
                if (c[1] == "source" && n >= 4) d = c[1] "/" c[2] "/" c[3]
                else if (n >= 4 && c[2] == "source") d = c[1] "/" c[2] "/" c[3]
                if (d != "") print d, p, $5, $6
            }' "$2"
    }
    lsfiles '' "$w/FILELIST.TXT" > "$w/files"
    # a tree whose FILELIST.TXT leaves out patches/: patches/FILE_LIST and its sums
    if ! grep -q '^patches/source/' "$w/files" && get "$mirror/$tree/patches/FILE_LIST" "$w/PFILE_LIST"; then
        lsfiles 'patches/' "$w/PFILE_LIST" >> "$w/files"
        if ! grep -q ' patches/' "$w/md5" && get "$mirror/$tree/patches/CHECKSUMS.md5" "$w/sums"; then
            checked 'patches/'
            say "- patches/: from patches/FILE_LIST; signature of patches/CHECKSUMS.md5: $sig"
        fi
    fi
    awk '{ print $1 }' "$w/files" | sort -u > "$w/dirs"
    awk '{ print $1, substr($2, length($1) + 2), $3, $4 }' "$w/files" > "$tdir/dirs.txt"
    say "- source directories: $(wc -l < "$w/dirs")"

    # the directories of the names asked for
    awk -v pat="^($pat)\$" '{ n = split($1, c, "/"); if (tolower(c[n]) ~ pat) print }' "$w/files" > "$w/sel"
    : > "$tdir/skipped.txt"
    : > "$w/found"
    say ""
    say "| Directory | Files fetched | Not fetched (size) | Failed |"
    say "|---|---|---|---|"
    for d in $(awk '{ print $1 }' "$w/sel" | sort -u); do
        name="${d##*/}"
        printf '%s\n' "$name" | tr 'A-Z' 'a-z' >> "$w/found"
        nf=0
        skipped=''
        bad=''
        awk -v d="$d" '$1 == d { print $2, $3 }' "$w/sel" > "$w/dfiles"
        while read -r p size; do
            case "$p" in *..* | /*) continue ;; esac
            if [ "$size" -gt "$maxsize" ]; then
                printf '%s %s\n' "$p" "$size" >> "$tdir/skipped.txt"
                skipped="$skipped ${p##*/} ($size);"
                continue
            fi
            mkdir -p "$tdir/$(dirname "$p")"
            # spaces in the URL are the one character of these paths to quote
            url="$mirror/$tree/$(printf '%s' "$p" | sed 's/ /%20/g')"
            if ! get "$url" "$tdir/$p"; then
                bad="$bad ${p##*/} ($(tail -n 1 "$w/curlerr" | tr '|' '/'));"
                rm -f "$tdir/$p"
                failed=1
                continue
            fi
            want="$(awk -v p="$p" '$2 == p { print $1; exit }' "$w/md5")"
            have="$(md5sum "$tdir/$p" | awk '{ print $1 }')"
            if [ -z "$want" ]; then
                bad="$bad ${p##*/} (not in CHECKSUMS.md5, kept);"
            elif [ "$want" != "$have" ]; then
                bad="$bad ${p##*/} (md5 differs from CHECKSUMS.md5, removed);"
                rm -f "$tdir/$p"
                failed=1
                continue
            fi
            nf=$((nf + 1))
        done < "$w/dfiles"
        say "| \`$d\` | $nf | ${skipped:-} | ${bad:-} |"
    done
    if [ -s "$w/found" ]; then
        missing="$(grep -v -x -F -f "$w/found" "$w/asked" | grep -v '[*]' | tr '\n' ' ')"
    else
        missing="$(grep -v '[*]' "$w/asked" | tr '\n' ' ')"
    fi
    say ""
    say "- not in this tree: ${missing:-none}"
    say ""
done
exit $failed
