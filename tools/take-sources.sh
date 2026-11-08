#!/bin/sh
# take-sources.sh - is the file of a take line the same from every source?
#
# Usage: sh tools/take-sources.sh <name>...
# Runs on the Ubuntu runner (workflow take-sources.yml) from the top of a checkout
# of master; needs curl, git, tar, xz, sha256sum, diff; gh (GH_TOKEN) for the
# GitHub release, gpg for a signature (both optional).
#
# A release taken before its port (a "take" line of freebsd/*.conf) must be the
# same file from the port's MASTER_SITES (the addresses of the line) and from the
# release of GitHub. For each name: fetches the file from every address of the
# line, not only the first that works, and the asset of the same name of the
# GitHub release of its upstream line; prints the size and SHA-256 of each and
# whether it is that of the take line; the publisher's checksum when there is one
# (digest.rdf, SHA256SUMS or <file>.sha256 next to an address, the digest GitHub
# keeps for the asset); a .asc signature, checked with gpg against every distinct
# file. When the files are not all the same, compares their trees, and compares
# each tree with the git tag of the upstream line (the generated files, configure
# and the like, are expected only in the release; a source file that differs from
# the tag is not).
#
# The report goes to report.md for tools/runs-report.sh. Exit status 0: every
# source gave the file of the take line; 1 otherwise; 2 usage.

set -u
top="$(pwd)"
work="${TAKE_SOURCES_WORK:-${TMPDIR:-/tmp}/take-sources.$$}"
rep="$top/report.md"
[ "$#" -gt 0 ] || { echo "usage: sh tools/take-sources.sh <name>..." >&2; exit 2; }
ls "$top"/freebsd/*.conf >/dev/null 2>&1 || { echo "take-sources: no freebsd/*.conf (run from the top of a checkout of master)" >&2; exit 2; }
for n in "$@"; do
    case "$n" in *[!a-z0-9_.+-]*|'') echo "take-sources: bad name: $n" >&2; exit 2 ;; esac
done

: > "$rep"
out() { printf '%s\n' "$*" | tee -a "$rep"; }
get() { curl -fsSL --retry 3 --retry-all-errors --retry-delay 5 --connect-timeout 30 --max-time 900 -o "$1" "$2" 2>"$1.err"; }
# a file that may well not be there: one try
probe() { rm -f "$1"; curl -fsSL --connect-timeout 20 --max-time 120 -o "$1" "$2" 2>/dev/null; }
size_of() { wc -c < "$1" | tr -d ' '; }
mkdir -p "$work"

# the digests named in a checksum file for <file>: digest.rdf (an rdf:about block) or
# lines of <sha256> <file>
sums_in() {
    awk -v f="$2" '
        index($0, "\"" f "\"") { b = 6 }
        b > 0 { b--; if (match($0, /[0-9a-f]{64}/)) print substr($0, RSTART, RLENGTH) }
        $0 ~ /^[0-9a-f]{64}[ \t]/ { n = $NF; sub(/^\*/, "", n); if (n == f) print $1 }
    ' "$1" | sort -u
}

rc=0
for n in "$@"; do
    t="$(awk -v n="$n" '$1 == "take" && $2 == n { print $3, $4, $5, $6; exit }' "$top"/freebsd/*.conf)"
    up="$(awk -v n="$n" '$1 == "upstream" && $2 == n { print $4; exit }' "$top"/freebsd/*.conf)"
    [ -n "$t" ] || { out "## $n"; out ""; out "FAIL: no take line of $n in freebsd/*.conf"; out ""; rc=1; continue; }
    # shellcheck disable=SC2086
    set -- $t
    ver="$1"; urls="$2"; sha="$3"; srcdir="$4"
    f="${urls%%,*}"; f="${f##*/}"
    w="$work/$n"; rm -rf "$w"; mkdir -p "$w"
    out "## $n $ver: $f"
    out ""
    out "take line: SHA-256 \`$sha\`; upstream: ${up:-none}"
    out ""
    out "| source | size | SHA-256 | the take line's |"
    out "|---|---|---|---|"
    i=0; got=""; dirs=""
    for u in $(echo "$urls" | tr ',' ' '); do
        i=$((i + 1))
        d="${u%/*}"
        case " $dirs " in *" $d "*) ;; *) dirs="$dirs $d" ;; esac
        if get "$w/m$i" "$u"; then
            s="$(sha256sum "$w/m$i" | cut -d' ' -f1)"
            if [ "$s" = "$sha" ]; then ok=yes; else ok="**no**"; rc=1; fi
            out "| $u | $(size_of "$w/m$i") | \`$s\` | $ok |"
            got="$got m$i:$s"
        else
            out "| $u | - | fetch failed: $(tr '\n' ' ' < "$w/m$i.err" | cut -c1-120) | - |"
            rm -f "$w/m$i"
        fi
    done

    # the GitHub release of the upstream line: its tag, its asset of the same name
    tag=""; gh_digest=""; assets=""
    if [ -n "$up" ] && git ls-remote --tags "$up" >"$w/tags" 2>/dev/null; then
        for c in "$ver" "v$ver" "release-$ver" "$srcdir" "$n-$ver"; do
            grep -q "	refs/tags/$c\$" "$w/tags" && { tag="$c"; break; }
        done
    fi
    case "$up" in
        https://github.com/*)
            repo="${up#https://github.com/}"; repo="${repo%.git}"; repo="${repo%/}"
            if [ -n "$tag" ] && command -v gh >/dev/null 2>&1 &&
                gh api "repos/$repo/releases/tags/$tag" --jq '.assets[] | [.name, .browser_download_url, (.digest // "-"), .size] | @tsv' >"$w/assets" 2>"$w/assets.err"; then
                assets="$(cut -f1 "$w/assets" | tr '\n' ' ')"
                a="$(awk -F'\t' -v f="$f" '$1 == f { print $2; exit }' "$w/assets")"
                gh_digest="$(awk -F'\t' -v f="$f" '$1 == f { sub(/^sha256:/, "", $3); print $3; exit }' "$w/assets")"
                if [ -n "$a" ]; then
                    if get "$w/gh" "$a"; then
                        s="$(sha256sum "$w/gh" | cut -d' ' -f1)"
                        if [ "$s" = "$sha" ]; then ok=yes; else ok="**no**"; rc=1; fi
                        out "| $a (GitHub release) | $(size_of "$w/gh") | \`$s\` | $ok |"
                        got="$got gh:$s"
                    else
                        out "| $a (GitHub release) | - | fetch failed: $(tr '\n' ' ' < "$w/gh.err" | cut -c1-120) | - |"
                    fi
                else
                    out "| GitHub release $tag | - | no asset $f | - |"
                fi
            else
                out "| GitHub release ${tag:-of $ver} | - | none or unreadable: $(tr '\n' ' ' < "$w/assets.err" 2>/dev/null | cut -c1-120) | - |"
            fi ;;
    esac
    out ""
    [ -z "$assets" ] || { out "assets of the GitHub release $tag: $assets"; out ""; }

    # the publisher's checksums
    for d in $dirs; do
        for c in digest.rdf SHA256SUMS sha256sums.txt "$f.sha256"; do
            probe "$w/sum" "$d/$c" || continue
            for s in $(sums_in "$w/sum" "$f"); do
                [ "$s" = "$sha" ] && ok="the take line's" || ok="not the take line's"
                case "$got" in *":$s"*) ok="$ok; that of$(echo "$got" | tr ' ' '\n' | awk -F: -v s="$s" '$2 == s { printf " %s", $1 }')" ;; esac
                out "- checksum in $d/$c: \`$s\` ($ok)"
            done
        done
    done
    [ -z "$gh_digest" ] || [ "$gh_digest" = - ] || out "- digest GitHub keeps for the asset: \`$gh_digest\`"

    # the distinct files: one of each SHA-256
    distinct="$(echo "$got" | tr ' ' '\n' | awk -F: 'NF == 2 && !seen[$2]++ { print $1 }')"
    nd="$(echo "$distinct" | grep -c .)"
    names_of() { echo "$got" | tr ' ' '\n' | awk -F: -v s="$1" '$2 == s { printf " %s", $1 }'; }

    # a signature next to an address or among the assets
    sig=""
    for d in $dirs; do probe "$w/sig" "$d/$f.asc" && { sig="$d/$f.asc"; break; }; done
    if [ -z "$sig" ] && [ -f "$w/assets" ]; then
        a="$(awk -F'\t' -v f="$f.asc" '$1 == f { print $2; exit }' "$w/assets")"
        [ -n "$a" ] && get "$w/sig" "$a" && sig="$a"
    fi
    if [ -n "$sig" ] && command -v gpg >/dev/null 2>&1; then
        export GNUPGHOME="$w/gnupg"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
        k="$(gpg --list-packets "$w/sig" 2>/dev/null | sed -n 's/.*keyid \([0-9A-Fa-f]*\).*/\1/p' | head -1)"
        [ -z "$k" ] || gpg -q --keyserver hkps://keyserver.ubuntu.com --recv-keys "$k" >/dev/null 2>&1 ||
            gpg -q --keyserver hkps://keys.openpgp.org --recv-keys "$k" >/dev/null 2>&1
        for m in $distinct; do
            v="$(gpg --status-fd 1 --verify "$w/sig" "$w/$m" 2>/dev/null | sed -n 's/^\[GNUPG:\] \(GOODSIG\|BADSIG\|ERRSIG\|NO_PUBKEY\|EXPKEYSIG\|REVKEYSIG\) \(.*\)/\1 \2/p' | head -1)"
            out "- signature $sig (key ${k:-?}) on$(names_of "$(sha256sum "$w/$m" | cut -d' ' -f1)"): ${v:-not checked}"
        done
    elif [ -n "$sig" ]; then
        out "- signature $sig: not checked (no gpg)"
    else
        out "- signature: none next to the addresses or among the assets"
    fi
    out ""

    if [ "$nd" -le 1 ]; then
        out "every source gave the same file"
        out ""
        continue
    fi

    # the trees of the distinct files, against each other and against the git tag
    for m in $distinct; do
        mkdir -p "$w/x-$m"
        tar -xf "$w/$m" -C "$w/x-$m" 2>"$w/x-$m.err" || out "- $m: extract failed: $(head -c 200 "$w/x-$m.err")"
    done
    first="$(echo "$distinct" | head -1)"
    for m in $(echo "$distinct" | sed 1d); do
        diff -rq "$w/x-$first" "$w/x-$m" | sed "s#$w/x-##g" > "$w/d-$m"
        out "### the tree of$(names_of "$(sha256sum "$w/$first" | cut -d' ' -f1)") against that of$(names_of "$(sha256sum "$w/$m" | cut -d' ' -f1)"): $(grep -c . "$w/d-$m") differences"
        out ""
        if [ -s "$w/d-$m" ]; then out '```'; head -60 "$w/d-$m" | tee -a "$rep"; out '```'; else
            out "the same files and contents: only the archive differs"
            for x in "$w/$first" "$w/$m"; do
                out "- $(basename "$x"): $(tar -tvf "$x" 2>/dev/null | head -1 | cut -c1-100)"
            done
        fi
        out ""
    done
    if [ -n "$tag" ] && git clone -q --depth 1 --branch "$tag" "$up" "$w/git" 2>"$w/git.err"; then
        for m in $distinct; do
            [ -d "$w/x-$m/$srcdir" ] || { out "- $m: no $srcdir in the archive"; continue; }
            diff -rq --exclude=.git "$w/x-$m/$srcdir" "$w/git" | sed "s#$w/x-$m/$srcdir#release#g; s#$w/git#tag#g" > "$w/g-$m"
            only_r="$(grep -c '^Only in release' "$w/g-$m")"
            only_t="$(grep -c '^Only in tag' "$w/g-$m")"
            grep '^Files ' "$w/g-$m" | awk '{ print $2 }' | sed 's#^release/##' > "$w/gd-$m"
            src="$(grep -E '\.(c|h|cc|cpp|cxx|hpp|S|asm|pl|py|sh|in|am|ac|m4|cmake|txt)$' "$w/gd-$m" | grep -vE '(^|/)(configure|aclocal\.m4|Makefile\.in|config\.h\.in|ChangeLog[^/]*)$')"
            out "### the tree of$(names_of "$(sha256sum "$w/$m" | cut -d' ' -f1)") against the tag $tag"
            out ""
            out "only in the release: $only_r ($(grep '^Only in release' "$w/g-$m" | sed 's/^Only in release[^:]*: //' | head -20 | tr '\n' ' ')); only in the tag: $only_t; files that differ: $(grep -c . "$w/gd-$m")"
            [ ! -s "$w/gd-$m" ] || out "differ: $(head -40 "$w/gd-$m" | tr '\n' ' ')"
            if [ -n "$src" ]; then out "**sources and build files that differ from the tag**: $(echo "$src" | head -40 | tr '\n' ' ')"; fi
            out ""
        done
    else
        out "- the git tag: not compared (tag ${tag:-not found}; $(head -c 200 "$w/git.err" 2>/dev/null))"
        out ""
    fi
done
rm -rf "$work"
exit "$rc"
