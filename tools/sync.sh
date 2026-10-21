#!/bin/sh
# shellcheck disable=SC2016
# (backticks in the printf formats below are markdown, not command substitution)
# sync.sh - maintain the freebsd/<target> branches of azsupport/php-src.
#
# For every target in freebsd/targets.conf:
#   1. resolve the upstream commit (Remi Collet's backport branch, or the newest
#      official php-src release tag of that minor version);
#   2. skip the target if freebsd/<target> already carries that upstream commit
#      and the same patch set (unless --force) - checked before any big fetch;
#   3. rebuild freebsd/<target> = upstream
#        + one commit applying the curated FreeBSD ports patches
#        + one commit adding the build id to the php -v banner (PHP_VERSION is
#          left untouched; php -v shows "... (fork: 20261021-fbsd-802c2107)")
#        + one commit prepending FreeBSD notes to README.md;
#   4. push the branch and mirror the upstream ref under its original name;
#   5. build a release tarball (tools/makedist.sh) and publish it as a GitHub
#      release, plus a moving "freebsd-<target>-latest" release.
#
# The branch README and the dated release notes list the ports patches that are
# applied and, with the reason from freebsd/patches/<target>/SKIPPED, the ones that
# are not. Regular runs also bring the notes of up-to-date targets in step with
# this script (only releases whose notes differ are edited).
#
# Usage: run inside a git clone of azsupport/php-src (remote 'origin'):
#   tools/sync.sh [--local] [--force] [--no-release] [--check] [--notes] [target ...]
#     --local       build branches locally only: no push, no releases
#     --force       rebuild even if nothing changed upstream
#     --no-release  push branches but do not build tarballs or releases
#     --check       only report which targets are up to date (no fetch, no push);
#                   with --notes, print the notes instead of updating the releases
#     --notes       only rewrite the notes of the releases of the current branch
#                   tips (no rebuild); the tips must carry the current patch set
#
# Environment:
#   FETCH_DEPTH     limit the upstream fetch depth (default: full history, which
#                   keeps pushes valid when the fork lacks new upstream history)
#   GH_REPO         repository for releases and API calls (default:
#                   $GITHUB_REPOSITORY or azsupport/php-src); needs gh + GH_TOKEN
#   GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL   commit identity (default: aZ)
#   EXTRA_TRAILERS  extra lines appended to generated commit messages
#   DIST_DIR        where tarballs are built (default: ./.sync-dist)

set -eu

# Bump when the generated branch content changes (commit layout, README block),
# so that every branch is rebuilt once. Tooling-only changes must not bump it;
# wording changes of the README block reach a branch with its next rebuild.
layout_version=4

main_dir="$(cd "$(dirname "$0")/.." && pwd)"
conf="$main_dir/freebsd/targets.conf"
gh_repo="${GH_REPO:-${GITHUB_REPOSITORY:-azsupport/php-src}}"
dist_dir="${DIST_DIR:-$(pwd)/.sync-dist}"
local_only=0 force=0 release=1 check_only=0 notes_only=0
while [ $# -gt 0 ]; do
    case "$1" in
        --local) local_only=1; release=0 ;;
        --check) check_only=1; release=0 ;;
        --force) force=1 ;;
        --no-release) release=0 ;;
        --notes) notes_only=1; release=0 ;;
        -*) echo "sync: unknown option $1" >&2; exit 2 ;;
        *) break ;;
    esac
    shift
done
want="$*"

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-aZ}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-github@azsupport.com}"
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-$GIT_AUTHOR_NAME}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-$GIT_AUTHOR_EMAIL}"

today="$(date -u +%Y%m%d)"
today_human="$(date -u +%d.%m.%Y)"

# Interim backports applied to the target being processed (one path per line).
bp_list="$(mktemp)"
trap 'rm -f "$bp_list"' EXIT

log() { printf '[sync] %s\n' "$*"; }
short() { printf '%s' "$1" | cut -c1-"${2:-12}"; }

sha256_of() {   # SHA-256 of stdin
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-64; else sha256 -q; fi
}

# Hash of everything a branch build is made of. SKIPPED is documentation only and
# deliberately not part of it.
patchset_of() {
    {
        cat "$patch_dir"/patch-*
        for b in "$patch_dir"/backport-*.patch; do if [ -f "$b" ]; then cat "$b"; fi; done
        echo "$target $url $ref $port $portrev layout=$layout_version"
    } | sha256_of
}

# Print "<commit-sha> <full-ref>" for a target's upstream (tags are peeled).
resolve_upstream() {
    url="$1" ref="$2"
    case "$ref" in
        latest-tag:*)
            prefix="${ref#latest-tag:}"
            tag="$(git ls-remote --tags --refs "$url" "refs/tags/${prefix}*" \
                   | awk '{print $2}' | sed 's#^refs/tags/##' \
                   | grep -E "^${prefix}[0-9]+\$" | sort -t. -k3,3n | tail -1)"
            [ -n "$tag" ] || return 1
            lines="$(git ls-remote --tags "$url" "refs/tags/$tag" "refs/tags/$tag^{}")"
            sha="$(printf '%s\n' "$lines" | awk '$2 ~ /\^\{\}$/ {print $1}')"
            [ -n "$sha" ] || sha="$(printf '%s\n' "$lines" | awk 'NR == 1 {print $1}')"
            printf '%s refs/tags/%s\n' "$sha" "$tag"
            ;;
        refs/heads/*)
            printf '%s %s\n' "$(git ls-remote "$url" "$ref" | awk 'NR == 1 {print $1}')" "$ref"
            ;;
        *) return 1 ;;
    esac
}

# Commit message of the current freebsd/<target> tip on GitHub, without fetching trees.
current_message() {
    tip="$(git ls-remote origin "refs/heads/$1" | awk 'NR == 1 {print $1}')"
    [ -n "$tip" ] || return 1
    gh api "repos/$gh_repo/git/commits/$tip" --jq .message
}

# Upstream description for the README and the release notes.
upstream_info() {
    up_web="${url%.git}"
    case "$up_ref" in
        refs/tags/*)
            up_name="${up_ref#refs/tags/}"
            summary="Official PHP $php_ver release ([php/php-src](https://github.com/php/php-src), tag \`$up_name\`) plus a few FreeBSD ports patches, for building PHP by hand on FreeBSD."
            ;;
        *)
            up_name="${up_ref#refs/heads/}"
            summary="PHP $target is end-of-life upstream. This branch follows Remi Collet's community security backports ([remicollet/php-src-security](https://github.com/remicollet/php-src-security), branch \`$up_name\`) and adds a few FreeBSD ports patches, for building PHP $target by hand on FreeBSD."
            ;;
    esac
    up_link="[${up_web#https://github.com/} \`$up_name\`]($up_web/tree/$up_name)"
}

port_url() { printf 'https://github.com/freebsd/freebsd-ports/tree/%s/lang/%s/files' "$portrev" "$port"; }

# Applied and not applied ports files as markdown lists. $1 is a line prefix
# ("> " inside the README block); the reasons come from SKIPPED, and files that
# share a reason are listed on one line.
ports_notes() {
    printf '%s**Applied** (commit "Apply curated FreeBSD ports patches"):\n%s\n' "$1" "${1% }"
    for p in "$patch_dir"/patch-*; do
        printf '%s- `%s` (`%s`): %s\n' "$1" "${p##*/}" \
            "$(grep -m1 '^+++ ' "$p" | awk '{print $2}')" \
            "$(sed -n 's/^Description: //p' "$p" | head -1)"
    done
    if [ -f "$patch_dir/SKIPPED" ]; then
        printf '%s\n%s**Not applied:**\n%s\n' "${1% }" "$1" "${1% }"
        grep -vE '^[[:space:]]*(#|$)' "$patch_dir/SKIPPED" | awk -v pfx="$1" '
            {
                i = index($0, ": ")
                f = "`" substr($0, 1, i - 1) "`"
                r = substr($0, i + 2)
                if (r in files) files[r] = files[r] ", " f
                else { order[++n] = r; files[r] = f }
            }
            END { for (k = 1; k <= n; k++) printf "%s- %s: %s\n", pfx, files[order[k]], order[k] }'
    fi
}

backports_notes() {   # $1: line prefix
    while IFS= read -r p; do
        printf '%s- %s (%s)\n' "$1" \
            "$(sed -n 's/^Description: //p' "$p" | head -1)" "$(sed -n 's/^Origin: //p' "$p" | head -1)"
    done < "$bp_list"
}

# README header for a target; uses the variables set in build_target().
readme_header() {
    upstream_info
    cat <<EOF
<!-- freebsd-notes:start -->
> [!IMPORTANT]
> **This is \`azsupport/php-src\`, branch \`freebsd/$target\`: not an official PHP release.**
>
> $summary
>
> | | |
> |---|---|
> | Upstream | $up_link @ \`$(short "$up_commit")\` |
> | PHP version | $php_ver (\`phpversion()\` unchanged); \`php -v\` adds \`(fork: $fork_build)\` |
> | FreeBSD patches | from freebsd-ports \`lang/$port\` @ \`$portrev\`: applied and not applied, below |
> | Ready-to-build tarball | [freebsd-$target-latest](https://github.com/$gh_repo/releases/tag/freebsd-$target-latest): \`configure\` and parsers are pre-generated, no autoconf/bison/re2c needed |
> | Updated | $today_human (UTC), automatically by [tools/sync.sh](https://github.com/$gh_repo/blob/HEAD/tools/sync.sh) |
>
> **FreeBSD ports patches** from freebsd-ports [\`lang/$port\` @ \`$portrev\`]($(port_url)):
>
EOF
    ports_notes "> "
    cat <<EOF
>
> The upstream \`.github/\` CI configuration is removed so that php-src CI does not
> run in this fork. Provided as is, without warranty.
EOF
    if [ -s "$bp_list" ]; then
        cat <<EOF

> [!WARNING]
> **Interim security backports by azsupport** (commit "Backport security fixes"),
> carried only until the upstream branch has its own fix; not reviewed upstream:
>
EOF
        backports_notes "> "
    fi
    cat <<EOF

The original PHP README follows.
<!-- freebsd-notes:end -->

EOF
}

# Apply patches and create the commits in worktree $wt (runs with set -e).
make_commits() {
    cd "$wt"
    for p in "$patch_dir"/patch-*; do
        if ! patch -p0 -N -s -f < "$p"; then
            echo "sync: $target: ${p##*/} does not apply" >&2
            return 1
        fi
    done
    # php-src's own CI configuration would run in this fork on every push; drop it.
    git rm -r -q --ignore-unmatch .github
    git add -u
    {
        echo "Apply curated FreeBSD ports patches"
        echo
        echo "From freebsd-ports lang/$port at $portrev:"
        for p in "$patch_dir"/patch-*; do echo "- ${p##*/}"; done
        echo
        echo "Also removes the upstream .github/ directory so that php-src CI does"
        echo "not run in this fork."
        if [ -n "${EXTRA_TRAILERS:-}" ]; then echo; printf '%s\n' "$EXTRA_TRAILERS"; fi
    } | git commit -q -F -

    # Optional interim backports (-p1, git format), skipped once upstream has them.
    # -f (not -t): -t guesses "reversed" patches and would fake the -R check.
    : > "$bp_list"
    for p in "$patch_dir"/backport-*.patch; do
        [ -f "$p" ] || continue
        if patch -p1 -R --dry-run -s -f < "$p" >/dev/null 2>&1; then
            echo "sync: $target: ${p##*/} is already upstream, skipped" >&2
            continue
        fi
        if ! patch -p1 -N -s -f < "$p"; then
            echo "sync: $target: ${p##*/} does not apply" >&2
            return 1
        fi
        echo "$p" >> "$bp_list"
    done
    if [ -s "$bp_list" ]; then
        git add -u
        {
            echo "Backport security fixes"
            echo
            echo "Interim backports carried until the upstream branch has its own fix:"
            while IFS= read -r p; do
                echo "- ${p##*/}: $(sed -n 's/^Description: //p' "$p" | head -1)"
                echo "  Origin: $(sed -n 's/^Origin: //p' "$p" | head -1)"
            done < "$bp_list"
            if [ -n "${EXTRA_TRAILERS:-}" ]; then echo; printf '%s\n' "$EXTRA_TRAILERS"; fi
        } | git commit -q -F -
    fi
    # Build id in the `php -v` banner only. PHP_VERSION is left at the upstream
    # value, so phpversion(), version_compare() and "PHP x.y.z" parsers are not
    # disturbed. configure regenerates main/php_version.h from configure.ac/.in, so
    # the PHP_FORK_BUILD macro is emitted there (right after PHP_VERSION_ID). The
    # banner format string then appends it by C string-literal concatenation, so no
    # printf argument changes. (This step runs on the CI runner / a Linux clone with
    # GNU sed, never on the FreeBSD servers.)
    [ -f configure.ac ] && vfile=configure.ac || vfile=configure.in
    sed -i "/^echo \"#define PHP_VERSION_ID /a echo '#define PHP_FORK_BUILD \"$fork_build\"' >> php_version.h.new" "$vfile"
    [ "$(grep -c 'PHP_FORK_BUILD' "$vfile")" = 1 ] || { echo "sync: $target: could not add PHP_FORK_BUILD to $vfile" >&2; return 1; }
    # The banner lives in main/main.c (8.2+, shared by every SAPI) or, before that,
    # in sapi/cli/php_cli.c. "$ver_banner" is empty if neither carries the string.
    ver_banner=""
    for f in main/main.c sapi/cli/php_cli.c; do
        if grep -q '(built: %s %s)' "$f" 2>/dev/null; then
            sed -i.orig 's/(built: %s %s)/(built: %s %s) (fork: " PHP_FORK_BUILD ")/' "$f"
            rm -f "$f.orig"
            ver_banner="$f"
            break
        fi
    done
    git add -u
    {
        if [ -n "$ver_banner" ]; then
            echo "Show the build id in the php -v banner: $php_ver (fork: $fork_build)"
            echo
            echo "php -v prints e.g. 'PHP $php_ver (cli) (built: ...) (fork: $fork_build)'."
            echo "PHP_VERSION stays $php_ver, so phpversion() and version checks are"
            echo "unchanged; the id (build date and upstream commit) rides in the banner"
            echo "via string-literal concatenation of the new PHP_FORK_BUILD macro"
            echo "(emitted into main/php_version.h by $vfile) in $ver_banner."
        else
            echo "Emit the PHP_FORK_BUILD macro: $fork_build"
            echo
            echo "The banner string was not found, so php -v is left unchanged."
        fi
        if [ -n "${EXTRA_TRAILERS:-}" ]; then echo; printf '%s\n' "$EXTRA_TRAILERS"; fi
    } | git commit -q -F -

    readme_header > README.md.new
    cat README.md >> README.md.new
    mv README.md.new README.md
    git add README.md
    {
        echo "README: describe the freebsd/$target branch"
        echo
        echo "Upstream-Ref: $url $up_ref"
        echo "Upstream-Commit: $up_commit"
        echo "Patchset: $patchset"
        echo "Fork-Build: $fork_build"
        while IFS= read -r p; do echo "Backport: ${p##*/}"; done < "$bp_list"
        if [ -n "${EXTRA_TRAILERS:-}" ]; then printf '%s\n' "$EXTRA_TRAILERS"; fi
    } | git commit -q -F -
}

# Release notes; $1 is the tarball file name. Needs php_ver, name, sha, new_tip.
release_notes() {
    upstream_info
    printf 'PHP %s for FreeBSD from branch [`%s`](https://github.com/%s/tree/%s), not an official PHP release.\n\n' \
        "$php_ver" "$branch" "$gh_repo" "$branch"
    printf '| | |\n|---|---|\n'
    printf '| Upstream | %s @ [`%s`](%s/commit/%s) |\n' "$up_link" "$(short "$up_commit")" "$up_web" "$up_commit"
    printf '| Branch commit | [`%s`](https://github.com/%s/commit/%s) |\n' "$(short "$new_tip")" "$gh_repo" "$new_tip"
    if [ -n "${fork_build:-}" ]; then
        printf '| `php -v` | `PHP %s (...) (fork: %s)` |\n' "$php_ver" "$fork_build"
    fi
    printf '| Tarball | `%s`, unpacks into `%s/` |\n' "$1" "$name"
    printf '| SHA-256 | `%s` |\n\n' "$sha"
    printf '### FreeBSD ports patches\n\nFrom freebsd-ports [`lang/%s` @ `%s`](%s).\n\n' "$port" "$portrev" "$(port_url)"
    ports_notes ""
    if [ -s "$bp_list" ]; then
        printf '\n### Interim security backports\n\nBy azsupport, carried only until the upstream branch has its own fix; not reviewed upstream:\n\n'
        backports_notes ""
    fi
    printf '\n### Build\n\nExtract, then in the new directory check the configure options of the installed build with [`tools/config-check.sh`](https://github.com/%s/blob/HEAD/tools/config-check.sh) (`sh config-check.sh /usr/local/phpXY /root/php-X.Y.Z/config.nice`, then `sh config.installed.sh`), then `make` and `make install`. See the [README](https://github.com/%s#readme).\n' "$gh_repo" "$gh_repo"
}

# Notes of the moving release: a pointer to the dated release, which carries the
# full notes, so that the releases page does not show everything twice.
latest_notes() {   # $1: tag of the dated release with the same tarball
    printf 'Moving release: always the newest build of [`%s`](https://github.com/%s/tree/%s), now PHP %s.\n\n' \
        "$branch" "$gh_repo" "$branch" "$php_ver"
    printf '| | |\n|---|---|\n'
    printf '| Tarball | `php-%s-fbsd-latest.tar.xz`, unpacks into `%s/` |\n' "$target" "$name"
    printf '| SHA-256 | `%s` |\n' "$sha"
    if [ -n "${fork_build:-}" ]; then
        printf '| `php -v` | `PHP %s (...) (fork: %s)` |\n' "$php_ver" "$fork_build"
    fi
    printf '| Same tarball as | [`%s`](https://github.com/%s/releases/tag/%s): upstream commit and the FreeBSD ports patches, applied and not applied |\n' \
        "$1" "$gh_repo" "$1"
}

# gh release create uploads into a draft and publishes it as the last step; when
# that step fails, the release stays a draft, whose downloads answer 404. Publish
# such drafts of this target that point at commit $1.
publish_drafts() {
    gh api "repos/$gh_repo/releases?per_page=100" \
        --jq ".[] | select(.draft and .target_commitish == \"$1\") | \"\(.id) \(.tag_name)\"" |
    while read -r id t; do
        case "$t" in "freebsd-$target-"*) ;; *) continue ;; esac
        if gh api -X PATCH "repos/$gh_repo/releases/$id" -F draft=false -f make_latest=false >/dev/null; then
            log "$target: published the draft release $t"
        else
            log "$target: warning: release $t is still a draft"
        fi
    done
}

publish_release() {
    short8="$(short "$up_commit" 8)"
    name="php-$php_ver-fbsd-$today-$short8"
    tag="freebsd-$target-$today-$short8"
    sh "$main_dir/tools/makedist.sh" "refs/heads/$branch" "$dist_dir" "$name"
    sha="$(cut -c1-64 "$dist_dir/$name.tar.xz.sha256")"
    # A second build of the same upstream commit on the same day (changed patch set
    # or --force) replaces that day's dated release.
    if gh api "repos/$gh_repo/releases/tags/$tag" >/dev/null 2>&1; then
        log "$target: replacing release $tag"
        gh release delete "$tag" --repo "$gh_repo" --yes --cleanup-tag
    fi
    gh release create "$tag" \
        "$dist_dir/$name.tar.xz" "$dist_dir/$name.tar.xz.sha256" \
        --repo "$gh_repo" --target "$new_tip" --latest=false \
        --title "PHP $php_ver for FreeBSD ($target, $today_human)" --notes "$(release_notes "$name.tar.xz")"
    latest="php-$target-fbsd-latest"
    cp "$dist_dir/$name.tar.xz" "$dist_dir/$latest.tar.xz"
    sed "s/  $name\\.tar\\.xz\$/  $latest.tar.xz/" "$dist_dir/$name.tar.xz.sha256" > "$dist_dir/$latest.tar.xz.sha256"
    gh release delete "freebsd-$target-latest" --repo "$gh_repo" --yes --cleanup-tag >/dev/null 2>&1 || true
    gh release create "freebsd-$target-latest" \
        "$dist_dir/$latest.tar.xz" "$dist_dir/$latest.tar.xz.sha256" \
        --repo "$gh_repo" --target "$new_tip" --latest=false \
        --title "PHP $target for FreeBSD: latest ($php_ver, $today_human)" \
        --notes "$(latest_notes "$tag")"
    rm -f "$dist_dir/$latest.tar.xz" "$dist_dir/$latest.tar.xz.sha256"
    publish_drafts "$new_tip"
    log "$target: released $name"
}

build_target() {
    target="$1" url="$2" ref="$3" port="$4" portrev="$5"
    patch_dir="$main_dir/freebsd/patches/$target"
    branch="freebsd/$target"

    resolved="$(resolve_upstream "$url" "$ref")" || { log "$target: cannot resolve $ref"; return 1; }
    up_commit="${resolved%% *}" up_ref="${resolved#* }"
    [ -n "$up_commit" ] && [ "$up_commit" != "$resolved" ] || { log "$target: cannot resolve $ref"; return 1; }

    patchset="$(patchset_of)"

    # Up to date? Decided from ls-remote + API before any large fetch.
    if [ "$force" = 0 ] && [ "$local_only" = 0 ] && msg="$(current_message "$branch" 2>/dev/null)"; then
        if [ "$(printf '%s\n' "$msg" | sed -n 's/^Upstream-Commit: //p')" = "$up_commit" ] &&
           [ "$(printf '%s\n' "$msg" | sed -n 's/^Patchset: //p')" = "$patchset" ]; then
            log "$target: up to date ($up_ref @ $(short "$up_commit"))"
            if [ "$release" = 1 ]; then
                refresh_notes "$target" "$url" "$ref" "$port" "$portrev" ||
                    log "$target: warning: could not refresh the release notes"
            fi
            return 0
        fi
    fi
    if [ "$check_only" = 1 ]; then
        log "$target: would rebuild ($up_ref @ $(short "$up_commit"))"
        return 0
    fi

    git fetch -q --no-tags ${FETCH_DEPTH:+--depth="$FETCH_DEPTH"} "$url" "+$up_ref:refs/sync/upstream/$target"
    [ "$(git rev-parse "refs/sync/upstream/$target^{commit}")" = "$up_commit" ] ||
        { log "$target: upstream moved during fetch, retry later"; return 1; }
    php_ver="$(git show "$up_commit:main/php_version.h" | sed -n 's/^#define PHP_VERSION "\(.*\)"/\1/p')"
    # php -v shows the build: build date and upstream commit, as in the tarball name.
    # The suffix starts with a digit, so that version_compare() ranks the build above
    # the plain upstream version (a leading letter would rank it below, like "-dev").
    # No dots: configure splits the version at them.
    fork_build="$today-fbsd-$(short "$up_commit" 8)"
    log "$target: building $branch from $up_ref @ $(short "$up_commit") (PHP $php_ver)"

    wt="$(mktemp -d)"
    git worktree add -q --detach "$wt" "$up_commit"
    set +e
    (set -e; make_commits)
    rc=$?
    set -e
    if [ "$rc" != 0 ]; then git worktree remove --force "$wt"; return 1; fi
    new_tip="$(git -C "$wt" rev-parse HEAD)"
    git worktree remove --force "$wt"
    git update-ref "refs/heads/$branch" "$new_tip"
    log "$target: $branch -> $(short "$new_tip")"

    [ "$local_only" = 1 ] && return 0

    # The old tip (one commit) shares most blobs with the new tree; having it locally
    # keeps the push small even when the fork lacks the new upstream history.
    git fetch -q --depth=1 origin "+refs/heads/$branch:refs/sync/current/$target" 2>/dev/null || true
    git push -q -f origin "refs/heads/$branch:refs/heads/$branch"
    log "$target: pushed $branch"
    # Best effort: keep the mirror of Remi's branch under its original name. Official
    # tags are not mirrored: pushing them would start php-src's tag-triggered CI here.
    case "$up_ref" in
        refs/heads/*)
            if git push -q -f origin "refs/sync/upstream/$target:$up_ref"; then
                log "$target: mirrored $up_ref"
            else
                log "$target: warning: could not mirror $up_ref (branch build is fine)"
            fi ;;
    esac

    if [ "$release" = 1 ]; then publish_release; fi
}

# --notes: rewrite the notes of the releases built from the current branch tip.
refresh_notes() {
    target="$1" url="$2" ref="$3" port="$4" portrev="$5"
    patch_dir="$main_dir/freebsd/patches/$target"
    branch="freebsd/$target"
    new_tip="$(git ls-remote origin "refs/heads/$branch" | awk 'NR == 1 {print $1}')"
    [ -n "$new_tip" ] || { log "$target: no branch $branch"; return 1; }
    msg="$(gh api "repos/$gh_repo/git/commits/$new_tip" --jq .message)"
    if [ "$(printf '%s\n' "$msg" | sed -n 's/^Patchset: //p')" != "$(patchset_of)" ]; then
        # The next regular run rebuilds it, with fresh notes.
        log "$target: $branch waits for a rebuild (patch set changed), notes left as they are"
        return 0
    fi
    if [ "$check_only" = 0 ]; then publish_drafts "$new_tip"; fi
    up_ref="$(printf '%s\n' "$msg" | sed -n 's/^Upstream-Ref: [^ ]* //p')"
    up_commit="$(printf '%s\n' "$msg" | sed -n 's/^Upstream-Commit: //p')"
    printf '%s\n' "$msg" | sed -n "s#^Backport: #$patch_dir/#p" > "$bp_list"
    tags="$(gh api "repos/$gh_repo/releases?per_page=100" \
        --jq ".[] | select(.target_commitish == \"$new_tip\") | .tag_name" | grep "^freebsd-$target-" || true)"
    tag="$(printf '%s\n' "$tags" | grep -v -- '-latest$' | head -1)"
    [ -n "$tag" ] || { log "$target: no release of $branch @ $(short "$new_tip")"; return 1; }
    assets="$(gh api "repos/$gh_repo/releases/tags/$tag" --jq '.assets[] | "\(.id) \(.name)"')"
    name="$(printf '%s\n' "$assets" | sed -n 's/^[0-9]* \(.*\)\.tar\.xz$/\1/p' | head -1)"
    php_ver="${name#php-}"
    php_ver="${php_ver%%-fbsd-*}"
    fork_build="$(printf '%s\n' "$msg" | sed -n 's/^Fork-Build: //p')"
    sha_id="$(printf '%s\n' "$assets" | awk -v f="$name.tar.xz.sha256" '$2 == f {print $1}')"
    sha="$(gh api -H 'Accept: application/octet-stream' "repos/$gh_repo/releases/assets/$sha_id" | cut -c1-64)"
    [ "${#sha}" = 64 ] || { log "$target: cannot read the SHA-256 of $tag"; return 1; }
    notes="$(release_notes "$name.tar.xz")"
    latest_tag="freebsd-$target-latest"
    if [ "$check_only" = 1 ]; then
        printf '%s\n\n----- %s:\n%s\n' "$notes" "$latest_tag" "$(latest_notes "$tag")"
        log "$target: would update the notes of $tag and $latest_tag"
        return 0
    fi
    # Edit only what differs, so that regular runs leave current notes alone.
    if [ "$(gh api "repos/$gh_repo/releases/tags/$tag" --jq .body)" != "$notes" ]; then
        gh release edit "$tag" --repo "$gh_repo" --notes "$notes" >/dev/null || return 1
        log "$target: notes of $tag updated"
    fi
    if printf '%s\n' "$tags" | grep -qx -- "$latest_tag"; then
        notes="$(latest_notes "$tag")"
        if [ "$(gh api "repos/$gh_repo/releases/tags/$latest_tag" --jq .body)" != "$notes" ]; then
            gh release edit "$latest_tag" --repo "$gh_repo" --notes "$notes" >/dev/null || return 1
            log "$target: notes of $latest_tag updated"
        fi
    fi
}

failed=""
targets="$(grep -vE '^[[:space:]]*(#|$)' "$conf")"
IFS_SAVE="$IFS"
IFS='
'
for line in $targets; do
    IFS="$IFS_SAVE"
    # shellcheck disable=SC2086
    set -- $line
    t="$1"
    if [ -n "$want" ]; then
        case " $want " in *" $t "*) ;; *) continue ;; esac
    fi
    set +e
    if [ "$notes_only" = 1 ]; then
        (set -e; refresh_notes "$@")
    else
        (set -e; build_target "$@")
    fi
    rc=$?
    set -e
    [ "$rc" = 0 ] || { log "$t: FAILED"; failed="$failed $t"; }
done
IFS="$IFS_SAVE"

if [ -n "$failed" ]; then
    log "failed targets:$failed"
    exit 1
fi
log "done"
