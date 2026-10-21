#!/bin/sh
# sync.sh - maintain the freebsd/<target> branches of azsupport/php-src.
#
# For every target in freebsd/targets.conf:
#   1. resolve the upstream commit (Remi Collet's backport branch, or the newest
#      official php-src release tag of that minor version);
#   2. skip the target if freebsd/<target> already carries that upstream commit
#      and the same patch set (unless --force) - checked before any big fetch;
#   3. rebuild freebsd/<target> = upstream
#        + one commit applying the curated FreeBSD ports patches
#        + one commit prepending FreeBSD notes to README.md;
#   4. push the branch and mirror the upstream ref under its original name;
#   5. build a release tarball (tools/makedist.sh) and publish it as a GitHub
#      release, plus a moving "freebsd-<target>-latest" release.
#
# Usage: run inside a git clone of azsupport/php-src (remote 'origin'):
#   tools/sync.sh [--local] [--force] [--no-release] [target ...]
#     --local       build branches locally only: no push, no releases
#     --force       rebuild even if nothing changed upstream
#     --no-release  push branches but do not build tarballs or releases
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

# Bump when the generated branch content changes (README block, commit layout),
# so that every branch is rebuilt once. Tooling-only changes must not bump it.
layout_version=2

main_dir="$(cd "$(dirname "$0")/.." && pwd)"
conf="$main_dir/freebsd/targets.conf"
gh_repo="${GH_REPO:-${GITHUB_REPOSITORY:-azsupport/php-src}}"
dist_dir="${DIST_DIR:-$(pwd)/.sync-dist}"
local_only=0 force=0 release=1
while [ $# -gt 0 ]; do
    case "$1" in
        --local) local_only=1; release=0 ;;
        --force) force=1 ;;
        --no-release) release=0 ;;
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

log() { printf '[sync] %s\n' "$*"; }
short() { printf '%s' "$1" | cut -c1-"${2:-12}"; }

sha256_of() {   # SHA-256 of stdin
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -c1-64; else sha256 -q; fi
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

# README header for a target; uses the variables set in build_target().
readme_header() {
    case "$up_ref" in
        refs/tags/*)
            up_name="${up_ref#refs/tags/}"
            summary="Official PHP $php_ver release ([php/php-src](https://github.com/php/php-src), tag \`$up_name\`) plus a few FreeBSD ports patches, for building PHP by hand on FreeBSD."
            up_link="[php/php-src \`$up_name\`](https://github.com/php/php-src/tree/$up_name)"
            ;;
        *)
            up_name="${up_ref#refs/heads/}"
            summary="PHP $target is end-of-life upstream. This branch follows Remi Collet's community security backports ([remicollet/php-src-security](https://github.com/remicollet/php-src-security), branch \`$up_name\`) and adds a few FreeBSD ports patches, for building PHP $target by hand on FreeBSD."
            up_link="[remicollet/php-src-security \`$up_name\`](https://github.com/remicollet/php-src-security/tree/$up_name)"
            ;;
    esac
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
> | PHP version | $php_ver |
> | FreeBSD patches | curated from freebsd-ports \`lang/$port\` @ \`$portrev\` (below) |
> | Ready-to-build tarball | [freebsd-$target-latest](https://github.com/$gh_repo/releases/tag/freebsd-$target-latest): \`configure\` and parsers are pre-generated, no autoconf/bison/re2c needed |
> | Updated | $today_human (UTC), automatically by [tools/sync.sh](https://github.com/$gh_repo/blob/main/tools/sync.sh) |
>
> FreeBSD ports patches applied on top of upstream (commit "Apply curated FreeBSD ports patches"):
EOF
    for p in "$patch_dir"/patch-*; do
        file="$(grep -m1 '^+++ ' "$p" | awk '{print $2}')"
        desc="$(sed -n 's/^Description: //p' "$p" | head -1)"
        printf '> - `%s`: %s\n' "$file" "$desc"
    done
    cat <<EOF
>
> Ports patches that only serve the ports' split-extension packaging, other CPU
> architectures or LibreSSL are intentionally not applied. The upstream \`.github/\`
> CI configuration is removed so that php-src CI does not run in this fork.
> Provided as is, without warranty. The original PHP README follows.
<!-- freebsd-notes:end -->

EOF
}

# Apply patches and create the two commits in worktree $wt (runs with set -e).
make_commits() {
    cd "$wt"
    for p in "$patch_dir"/patch-*; do
        if ! patch -p0 -N -s -t < "$p"; then
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
        if [ -n "${EXTRA_TRAILERS:-}" ]; then printf '%s\n' "$EXTRA_TRAILERS"; fi
    } | git commit -q -F -
}

publish_release() {
    short8="$(short "$up_commit" 8)"
    name="php-$php_ver-fbsd-$today-$short8"
    sh "$main_dir/tools/makedist.sh" "refs/heads/$branch" "$dist_dir" "$name"
    sha="$(cut -c1-64 "$dist_dir/$name.tar.xz.sha256")"
    notes="$(printf 'PHP %s for FreeBSD, branch `%s`.\n\nUpstream: %s `%s` @ `%s`\n\nSHA-256 (%s.tar.xz): `%s`\n\nBuild: extract, run `./configure` with your usual options (or `sh config.nice` from your previous build), `make`, `make install`. See the [README](https://github.com/%s/tree/main#readme).' \
        "$php_ver" "$branch" "$url" "$up_ref" "$up_commit" "$name" "$sha" "$gh_repo")"
    gh release create "freebsd-$target-$today-$short8" \
        "$dist_dir/$name.tar.xz" "$dist_dir/$name.tar.xz.sha256" \
        --repo "$gh_repo" --target "$new_tip" --latest=false \
        --title "PHP $php_ver for FreeBSD ($target, $today_human)" --notes "$notes"
    latest="php-$target-fbsd-latest"
    cp "$dist_dir/$name.tar.xz" "$dist_dir/$latest.tar.xz"
    sed "s/  $name\\.tar\\.xz\$/  $latest.tar.xz/" "$dist_dir/$name.tar.xz.sha256" > "$dist_dir/$latest.tar.xz.sha256"
    gh release delete "freebsd-$target-latest" --repo "$gh_repo" --yes --cleanup-tag >/dev/null 2>&1 || true
    gh release create "freebsd-$target-latest" \
        "$dist_dir/$latest.tar.xz" "$dist_dir/$latest.tar.xz.sha256" \
        --repo "$gh_repo" --target "$new_tip" --latest=false \
        --title "PHP $target for FreeBSD: latest ($php_ver, $today_human)" \
        --notes "$(printf 'Moving release: always the newest build of `%s`.\nThe tarball unpacks into `%s/`.\n\n%s' "$branch" "$name" "$notes")"
    rm -f "$dist_dir/$latest.tar.xz" "$dist_dir/$latest.tar.xz.sha256"
    log "$target: released $name"
}

build_target() {
    target="$1" url="$2" ref="$3" port="$4" portrev="$5"
    patch_dir="$main_dir/freebsd/patches/$target"
    branch="freebsd/$target"

    resolved="$(resolve_upstream "$url" "$ref")" || { log "$target: cannot resolve $ref"; return 1; }
    up_commit="${resolved%% *}" up_ref="${resolved#* }"
    [ -n "$up_commit" ] && [ "$up_commit" != "$resolved" ] || { log "$target: cannot resolve $ref"; return 1; }

    patchset="$( { cat "$patch_dir"/patch-*; echo "$target $url $ref $port $portrev layout=$layout_version"; } | sha256_of)"

    # Up to date? Decided from ls-remote + API before any large fetch.
    if [ "$force" = 0 ] && [ "$local_only" = 0 ] && msg="$(current_message "$branch" 2>/dev/null)"; then
        if [ "$(printf '%s\n' "$msg" | sed -n 's/^Upstream-Commit: //p')" = "$up_commit" ] &&
           [ "$(printf '%s\n' "$msg" | sed -n 's/^Patchset: //p')" = "$patchset" ]; then
            log "$target: up to date ($up_ref @ $(short "$up_commit"))"
            return 0
        fi
    fi

    git fetch -q --no-tags ${FETCH_DEPTH:+--depth="$FETCH_DEPTH"} "$url" "+$up_ref:refs/sync/upstream/$target"
    [ "$(git rev-parse "refs/sync/upstream/$target^{commit}")" = "$up_commit" ] ||
        { log "$target: upstream moved during fetch, retry later"; return 1; }
    php_ver="$(git show "$up_commit:main/php_version.h" | sed -n 's/^#define PHP_VERSION "\(.*\)"/\1/p')"
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
    (set -e; build_target "$@")
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
