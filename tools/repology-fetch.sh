#!/bin/sh
# repology-fetch.sh - the versions of the software of the ports of azsupport/ports in
# the other distributions: every repository Repology (https://repology.org) follows,
# for the table of azsupport/azsupport that compares them with ours (its
# db/distro-versions.tsv, tools/db/import-distro-versions.py). Repology is closed to
# the sandbox of Claude Code, GitHub is not. Workflow:
# .github/workflows/repology-fetch.yml.
#
# Usage:
#   sh tools/repology-fetch.sh fetch <out dir> [<origin>...]
#       <origin>: a port of azsupport/ports (category/port) or a library of azsupport
#       (azsupport:<name>, a "lib" line of its deps.conf); none: every port of main
#       of azsupport/ports and every library of azsupport
#   sh tools/repology-fetch.sh push <out dir>
#       commit what a fetch wrote into the branch runs of azsupport/azsupport,
#       distro/repology/<YYYY-MM-DD>/ (needs RUNS_TOKEN)
# Environment:
#   PORTS        fetch: a checkout of azsupport/ports to read (default: a shallow
#                clone of its main)
#   RUNS_TOKEN   push: a token with Contents read and write on azsupport/azsupport
#                (the secret of tools/runs-report.sh)
#   RUNS_REMOTE  push: the repository to commit to instead (a path, for a test)
# From an origin to a project of Repology: tools/repology-map.conf, a sed -E script,
# turns the origin (for a library: the FreeBSD port deps.conf or curl-deps.conf
# names) into a port of the FreeBSD tree, project:<name> or -:<why>; a FreeBSD port
# is looked up with https://repology.org/tools/project-by (repo freebsd, srcname;
# with noautoresolve: every project when it is in several), each project then once
# with https://repology.org/api/v1/project/<name>. The rules of Repology
# (https://repology.org/api): at most one request a second, and a User-Agent that
# names the tool and a contact.
# What a fetch writes into <out dir>:
#   repology.tsv   a package of a project per line (TAB): project, repo, subrepo,
#                  srcname, binname, version, status, origversion, vulnerable (the
#                  fields of /api/v1/project; empty: Repology gives none); a push
#                  puts it at distro/repology/<date>/<run id>.tsv
#   origins.tsv    an origin per line (TAB): origin, what was asked (a FreeBSD port,
#                  project:<name>, -:<why>), the project (several: separated by
#                  spaces; empty: none), how (freebsd: by project-by; map: the
#                  project the map names; none; not-found: project-by knows no such
#                  srcname; error <HTTP code>), the number of packages of its
#                  projects; a push: distro/repology/<date>/<run id>-origins.tsv
#   report.md      the reference point (the commit of azsupport/ports, the sha256 of
#                  the map), the counts, the origins without a project and why, the
#                  projects without packages, the failed requests (the summary of the
#                  run; a push: distro/repology/<date>/<run id>.md)
# The exit status of a fetch is 1 when a request failed: the rest is still written,
# and report.md names what failed.

set -u
set -f
LC_ALL=C
export LC_ALL
cmd="${1:-}"
[ $# -gt 0 ] && shift
usage() {
    echo "usage: sh tools/repology-fetch.sh fetch <out dir> [<origin>...]" >&2
    echo "       sh tools/repology-fetch.sh push <out dir>" >&2
    exit 2
}
w="$(mktemp -d)"
trap 'rm -rf "$w"' EXIT
here="$(cd "$(dirname "$0")" && pwd)"

# ---------------------------------------------------------------------------- push
if [ "$cmd" = push ]; then
    [ $# -eq 1 ] || usage
    src="$(cd "$1" && pwd)" || exit 1
    remote="${RUNS_REMOTE:-}"
    if [ -z "$remote" ]; then
        if [ -z "${RUNS_TOKEN:-}" ]; then
            echo "::warning title=repology fetch::RUNS_TOKEN is not set: nothing committed to azsupport/azsupport (branch runs)"
            exit 0
        fi
        remote="https://x-access-token:${RUNS_TOKEN}@github.com/azsupport/azsupport.git"
    fi
    hide() { sed 's#x-access-token:[^@]*@#x-access-token:***@#g'; }
    day="$(date -u +%Y-%m-%d)"
    run="${GITHUB_RUN_ID:-0}"
    r="$w/runs"
    # the branch has hundreds of thousands of files: without their blobs, and only
    # distro/repology checked out
    if ! git clone -q --depth 1 --filter=blob:none --sparse --branch runs --single-branch "$remote" "$r" 2>"$w/err" ||
        ! git -C "$r" sparse-checkout set distro/repology 2>>"$w/err"; then
        echo "::error title=repology fetch::clone of azsupport/azsupport (runs) failed: $(hide < "$w/err" | tail -n 2 | tr '\n' ' ')"
        exit 1
    fi
    # the identity of the commit and of a rebase onto the pushes of other runs
    git -C "$r" config user.name 'github-actions[bot]'
    git -C "$r" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
    base="distro/repology/$day"
    mkdir -p "$r/$base"
    {
        echo "# repology-fetch — $day"
        echo
        echo "- run: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-azsupport/php-src}/actions/runs/$run (attempt ${GITHUB_RUN_ATTEMPT:-1})"
        echo "- commit: ${GITHUB_SHA:-?} $(git log -1 --format=%s 2>/dev/null)"
        echo "- written: $(date -u '+%Y-%m-%d %H:%M UTC')"
        echo "- files: $base/$run.tsv (the packages of the projects), $base/$run-origins.tsv (origin and project)"
        echo
        if [ -s "$src/report.md" ]; then cat "$src/report.md"; else echo "(no report: the fetch wrote none)"; fi
    } > "$r/$base/$run.md"
    [ -f "$src/repology.tsv" ] && cp "$src/repology.tsv" "$r/$base/$run.tsv"
    [ -f "$src/origins.tsv" ] && cp "$src/origins.tsv" "$r/$base/$run-origins.tsv"
    git -C "$r" add -A "$base"
    git -C "$r" commit -q -m "repology-fetch: run $run" || { echo "::error title=repology fetch::commit failed"; exit 1; }
    # other runs push into runs too: on a refused push, rebase and again
    i=0
    : > "$w/err"
    while [ $i -lt 6 ]; do
        i=$((i + 1))
        if git -C "$r" push -q origin HEAD:runs 2>>"$w/err"; then
            echo "repology fetch: $base/$run.md"
            exit 0
        fi
        sleep $((i * 5))
        git -C "$r" pull -q --rebase origin runs 2>>"$w/err" || git -C "$r" rebase --abort 2>/dev/null
    done
    echo "::error title=repology fetch::push to azsupport/azsupport (runs) failed: $(hide < "$w/err" | tail -n 3 | tr '\n' ' ')"
    exit 1
fi

# --------------------------------------------------------------------------- fetch
if [ "$cmd" != fetch ] || [ $# -lt 1 ]; then
    usage
fi
out="$1"
shift
mkdir -p "$out" || exit 1
conf="$here/repology-map.conf"
[ -f "$conf" ] || { echo "repology fetch: no $conf" >&2; exit 1; }
BASE="https://repology.org"
UA="repology-fetch.sh/1 (azsupport/php-src; +https://github.com/azsupport/php-src; github@azsupport.com)"

ports="${PORTS:-}"
if [ -z "$ports" ]; then
    ports="$w/ports"
    git clone -q --depth 1 https://github.com/azsupport/ports "$ports" 2>"$w/err" || {
        echo "::error title=repology fetch::clone of azsupport/ports failed: $(tail -n 2 "$w/err" | tr '\n' ' ')"
        exit 1
    }
fi
pcommit="$(git -C "$ports" rev-parse HEAD 2>/dev/null || echo '?')"
deps="$ports/azsupport/azsupport/files/deps.conf"
cdeps="$ports/azsupport/azsupport/files/curl-deps.conf"

# the list: origin TAB what is given to the map (the origin; for a library the port
# of deps.conf, or of curl-deps.conf for one of the bundled curl)
git -C "$ports" ls-files | awk -F/ 'NF == 3 && $3 == "Makefile" && $1 !~ /^(Mk|tools|keys)$/ {
    print $1 "/" $2 "\t" $1 "/" $2 }' | sort -u > "$w/all"
if [ -f "$deps" ]; then
    awk -v cdeps="$cdeps" 'BEGIN {
            while ((getline l < cdeps) > 0) {
                if (l ~ /^#/) continue
                split(l, f, /[ \t]+/)
                if (f[3] ~ /\//) port[f[1]] = f[3]
            }
        }
        $1 == "lib" {
            p = $3
            if (p == "bundle") p = ($2 in port) ? port[$2] : "azsupport:" $2
            print "azsupport:" $2 "\t" p
        }' "$deps" >> "$w/all"
fi
if [ $# -gt 0 ]; then
    printf '%s\n' "$@" > "$w/want"
    awk -F '\t' 'NR == FNR { want[$1] = 1; next } ($1 in want) { print; seen[$1] = 1 }
        END { for (o in want) if (!(o in seen)) print o > "/dev/stderr" }' "$w/want" "$w/all" > "$w/list" 2>"$w/unknown"
else
    cp "$w/all" "$w/list"
    : > "$w/unknown"
fi
cut -f2 "$w/list" | sed -E -f "$conf" > "$w/keys"
if [ "$(wc -l < "$w/keys" | tr -d ' ')" != "$(wc -l < "$w/list" | tr -d ' ')" ]; then
    echo "::error title=repology fetch::$conf gave $(wc -l < "$w/keys" | tr -d ' ') lines for $(wc -l < "$w/list" | tr -d ' ') origins"
    exit 1
fi
paste "$w/list" "$w/keys" | cut -f1,3 > "$w/okeys"

# one request at a time and at most one a second; 429, 5xx and no answer: again after
# a pause, three times. Prints "<HTTP code> <redirect URL>".
req() {
    n=0
    while :; do
        n=$((n + 1))
        res="$(curl -sS -m 60 -A "$UA" -o "$2" -w '%{http_code} %{redirect_url}' "$1" 2>>"$w/curl.err")" || res="000 "
        sleep 1
        case "${res%% *}" in
            429|500|502|503|504|000)
                [ $n -lt 4 ] || break
                sleep $((n * 20))
                ;;
            *) break ;;
        esac
    done
    echo "$res"
}
sum256() {
    if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -d ' ' -f 1; else sha256 -q "$1"; fi
}
urlenc() {
    printf '%s' "$1" | awk 'BEGIN { for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i }
        { s = ""; n = length($0)
          for (i = 1; i <= n; i++) {
              c = substr($0, i, 1)
              if (c ~ /[A-Za-z0-9._~-]/) s = s c; else s = s sprintf("%%%02X", ord[c])
          }
          printf "%s", s }'
}
urldec() {
    printf '%s\n' "$1" | awk 'BEGIN { for (i = 1; i < 256; i++) { hex[sprintf("%02X", i)] = sprintf("%c", i); hex[sprintf("%02x", i)] = sprintf("%c", i) } }
        { s = $0; o = ""
          while ((i = index(s, "%")) > 0) {
              o = o substr(s, 1, i - 1); h = substr(s, i + 1, 2)
              if (h in hex) { o = o hex[h]; s = substr(s, i + 3) } else { o = o "%"; s = substr(s, i + 1) }
          }
          print o s }'
}

# /api/v1/project/<name>: a JSON array of flat objects -> a line per object (TAB):
# project and the fields below. Records split at the double quotes: outside a
# string the structure, inside the string, an odd number of backslashes before the
# quote an escaped one (the string goes on).
cat > "$w/json.awk" <<'EOF'
BEGIN {
    RS = "\""; depth = 0; instr = 0; buf = ""; key = ""; want = "key"; lit = ""
    nf = split("repo subrepo srcname binname version status origversion vulnerable", F, " ")
}
function unesc(s,    o, i, c, n) {
    if (index(s, "\\") == 0) return s
    o = ""; n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c != "\\") { o = o c; continue }
        i++; c = substr(s, i, 1)
        if (c == "n" || c == "t" || c == "r" || c == "b" || c == "f") o = o " "
        else if (c == "u") { o = o "\\u" substr(s, i + 1, 4); i += 4 }
        else o = o c
    }
    return o
}
function emit(    i, v, line) {
    line = project
    for (i = 1; i <= nf; i++) {
        v = (F[i] in f) ? f[F[i]] : ""
        gsub(/[\t\r\n]/, " ", v)
        line = line "\t" v
    }
    print line
    for (v in f) delete f[v]
}
function endlit() {
    if (depth == 2 && want == "value" && lit != "") { f[key] = lit; want = "after" }
    lit = ""
}
function struct(s,    i, n, c) {
    n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "{") { depth++; if (depth == 2) want = "key" }
        else if (c == "}") { endlit(); if (depth == 2) emit(); depth-- }
        else if (c == "[") depth++
        else if (c == "]") depth--
        else if (c == ":") { if (depth == 2) { want = "value"; lit = "" } }
        else if (c == ",") { endlit(); if (depth == 2) want = "key" }
        else if (c == " " || c == "\t" || c == "\r" || c == "\n") continue
        else if (depth == 2 && want == "value") lit = lit c
    }
}
{
    if (!instr) { struct($0); instr = 1; next }
    s = buf $0
    n = 0; i = length(s)
    while (i > 0 && substr(s, i, 1) == "\\") { n++; i-- }
    if (n % 2) { buf = s "\""; next }
    buf = ""; instr = 0
    s = unesc(s)
    if (depth == 2 && want == "key") key = s
    else if (depth == 2 && want == "value") { f[key] = s; want = "after" }
}
EOF

# each FreeBSD port once: project-by
fails=0
: > "$w/kp"
: > "$w/failed"
cut -f2 "$w/okeys" | sort -u > "$w/ukeys"
while IFS= read -r k; do
    case "$k" in
        -:*) printf '%s\t\tnone\n' "$k" >> "$w/kp" ;;
        project:?*) printf '%s\t%s\tmap\n' "$k" "${k#project:}" >> "$w/kp" ;;
        [a-z0-9]*/?*)
            res="$(req "$BASE/tools/project-by?repo=freebsd&name_type=srcname&target_page=api_v1_project&noautoresolve=1&name=$(urlenc "$k")" "$w/body")"
            code="${res%% *}"
            loc="${res#* }"
            case "$code" in
                301|302|303|307|308)
                    case "$loc" in
                        */api/v1/project/?*) printf '%s\t%s\tfreebsd\n' "$k" "$(urldec "${loc##*/api/v1/project/}")" >> "$w/kp" ;;
                        *) printf '%s\t\terror %s (%s)\n' "$k" "$code" "$loc" >> "$w/kp"; fails=$((fails + 1)) ;;
                    esac
                    ;;
                300)
                    # several projects: all of them
                    p="$(grep -o '/api/v1/project/[^"<> ]*' "$w/body" | sed 's#^/api/v1/project/##' |
                        while IFS= read -r x; do urldec "$x"; done | sort -u | tr '\n' ' ' | sed 's/ $//')"
                    printf '%s\t%s\tfreebsd\n' "$k" "$p" >> "$w/kp"
                    ;;
                404) printf '%s\t\tnot-found\n' "$k" >> "$w/kp" ;;
                *)
                    printf '%s\t\terror %s\n' "$k" "$code" >> "$w/kp"
                    printf '%s\n' "project-by $k: HTTP $code" >> "$w/failed"
                    fails=$((fails + 1))
                    ;;
            esac
            ;;
        *) printf '%s\t\tnot-found\n' "$k" >> "$w/kp" ;;
    esac
done < "$w/ukeys"

# each project once: its packages
: > "$out/repology.tsv"
: > "$w/pcount"
cut -f2 "$w/kp" | tr ' ' '\n' | sed '/^$/d' | sort -u > "$w/projects"
while IFS= read -r p; do
    res="$(req "$BASE/api/v1/project/$(urlenc "$p")" "$w/pj")"
    code="${res%% *}"
    if [ "$code" = 200 ]; then
        awk -v project="$p" -f "$w/json.awk" "$w/pj" > "$w/rows"
        cat "$w/rows" >> "$out/repology.tsv"
        printf '%s\t%s\n' "$p" "$(wc -l < "$w/rows" | tr -d ' ')" >> "$w/pcount"
    else
        printf '%s\t-1\n' "$p" >> "$w/pcount"
        printf '%s\n' "project $p: HTTP $code" >> "$w/failed"
        fails=$((fails + 1))
    fi
done < "$w/projects"

# origin, asked, project, how, packages
awk -F '\t' 'FILENAME == ARGV[1] { proj[$1] = $2; how[$1] = $3; next }
    FILENAME == ARGV[2] { cnt[$1] = $2; next }
    { n = split(proj[$2], ps, " "); c = 0; bad = 0
      for (i = 1; i <= n; i++) { if (cnt[ps[i]] < 0) bad = 1; else c += cnt[ps[i]] }
      print $1 "\t" $2 "\t" proj[$2] "\t" how[$2] "\t" (bad ? "?" : c) }' \
    "$w/kp" "$w/pcount" "$w/okeys" > "$out/origins.tsv"

# the report
{
    echo "### Repology fetch"
    echo
    echo "- azsupport/ports: $pcommit; tools/repology-map.conf: sha256 $(sum256 "$conf")"
    echo "- origins: $(wc -l < "$out/origins.tsv" | tr -d ' ') ($(grep -c -v '^azsupport:' "$out/origins.tsv") ports, $(grep -c '^azsupport:' "$out/origins.tsv") libraries of azsupport); asked: $(wc -l < "$w/ukeys" | tr -d ' ') ($(grep -c '/' "$w/ukeys") FreeBSD ports)"
    awk -F '\t' '{ h = $4; sub(/ .*/, "", h); if ($4 ~ /^(freebsd|map)$/ && $5 == "0") h = "no-packages"; n[h]++ }
        END { printf "- by how: "; s = ""; for (h in n) { printf "%s%s %d", s, h, n[h]; s = ", " } print "" }' "$out/origins.tsv"
    echo "- projects: $(wc -l < "$w/projects" | tr -d ' '); packages: $(wc -l < "$out/repology.tsv" | tr -d ' ') in $(cut -f2 "$out/repology.tsv" | sort -u | wc -l | tr -d ' ') repositories"
    echo "- requests failed: $fails"
    if [ -s "$w/unknown" ]; then
        echo
        echo "Origins asked for that are neither ports of the tree nor libraries of azsupport: $(tr '\n' ' ' < "$w/unknown")"
    fi
    if awk -F '\t' '$4 != "freebsd" && $4 != "map" { f = 1 } END { exit !f }' "$out/origins.tsv"; then
        echo
        echo "Without a project:"
        echo
        echo "| origin | asked | how |"
        echo "|---|---|---|"
        awk -F '\t' '$4 != "freebsd" && $4 != "map" { print "| " $1 " | " $2 " | " $4 " |" }' "$out/origins.tsv"
    fi
    if awk -F '\t' '$2 == "0" { f = 1 } END { exit !f }' "$w/pcount"; then
        echo
        echo "Projects Repology has no packages of (no such project): $(awk -F '\t' '$2 == "0" { printf "%s%s", s, $1; s = ", " }' "$w/pcount")"
        echo
        echo "| origin | project |"
        echo "|---|---|"
        awk -F '\t' 'NR == FNR { if ($2 == "0") z[$1] = 1; next } ($3 in z) { print "| " $1 " | " $3 " |" }' "$w/pcount" "$out/origins.tsv"
    fi
    if [ -s "$w/failed" ]; then
        echo
        echo "Failed: $(tr '\n' ';' < "$w/failed")"
        [ -s "$w/curl.err" ] && echo "curl: $(sort -u "$w/curl.err" | tail -n 5 | tr '\n' ' ')"
    fi
} > "$out/report.md"
cat "$out/report.md"
[ "$fails" -eq 0 ]
