#!/bin/sh
# config-check.sh - before reusing a config.nice for a rebuild, compare its
# ./configure options with those of the PHP build that is actually installed.
# The installed build wins: a config script with the installed build's options,
# config.installed.sh, is always written to the current directory; run that one.
#
# Usage (FreeBSD /bin/sh; from csh run it with sh):
#   sh config-check.sh /usr/local/php81
#   sh config-check.sh /usr/local/php81 /root/php-8.1.34/config.nice
#
#   The first argument is a php, php-fpm or php-cgi binary, or an install prefix
#   (bin/php, sbin/php-fpm or bin/php-cgi inside it is used).
#   The second argument is the config.nice of the old build. Without it,
#   ./config.nice is used, or else the newest php-<version>/config.nice or
#   php-<version>-*/config.nice next to the current directory or in $HOME, where
#   <version> is the installed version (php-8.1.34, php-8.1.34-fbsd-20261021-...).
#   Run it from inside the new PHP source tree, then: sh config.installed.sh
#   OUT=/path/file.sh overrides where the script goes (default: ./config.installed.sh).
#
# The installed options come from "<binary> -n -i" (Configure Command; -n skips
# php.ini, so a broken shared extension does not get in the way) or, failing that,
# from php-config --configure-options next to the binary. Environment lines of
# config.nice (CFLAGS=... and the like) are shown and carried over, but not
# compared: the installed build does not record them. PHP 5.6 records options with
# spaces in a broken quoting ('CFLAGS=-O3 '-pipe' '-march=...''); both sources are
# split the way the shell would, so such an option stays one option.
#
# Exit status: 0 same options, 1 different (or no config.nice to compare with),
# 2 usage or read error.

set -u

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    sed -n 's/^# \{0,1\}//; 7,9p' "$0" >&2
    exit 2
fi
target="$1"
nice="${2:-}"
out="${OUT:-./config.installed.sh}"

if [ -d "$target" ]; then
    php=""
    for c in bin/php sbin/php-fpm bin/php-cgi; do
        if [ -x "$target/$c" ]; then php="$target/$c"; break; fi
    done
    [ -n "$php" ] || { echo "config-check: no bin/php, sbin/php-fpm or bin/php-cgi in $target" >&2; exit 2; }
else
    php="$target"
fi
[ -x "$php" ] || { echo "config-check: $php is not an executable file" >&2; exit 2; }

tmp="$(mktemp -d)" || exit 2
trap 'rm -rf "$tmp"' EXIT INT TERM

# One option per line, split like the shell splits words (quotes removed, adjacent
# quoted parts joined; xargs only parses, it runs nothing but printf). Falls back
# to taking every '...' group if xargs rejects the quoting. The ./configure path
# itself is dropped.
to_lines() {
    if ! printf '%s\n' "$1" | xargs -n 1 printf '%s\n' > "$tmp/split" 2>/dev/null; then
        echo "config-check: warning: unbalanced quotes in the options from ${2:-?}" \
             "(a PHP 5.6 value that ends in a space?); options with spaces may come out split" >&2
        case "$1" in
            *\'*) printf '%s\n' "$1" | grep -o "'[^']*'" | sed "s/^'//; s/'\$//" ;;
            *) printf '%s\n' "$1" | tr -s '[:blank:]' '\n' ;;
        esac > "$tmp/split"
    fi
    grep -v -e '^$' -e '^[^-].*configure$' "$tmp/split"
}

# Installed build.
line="$("$php" -n -i 2>/dev/null | sed -n 's/^Configure Command =>[[:space:]]*//p' | head -1)"
how="$php -n -i"
if [ -z "$line" ]; then
    pc="$(dirname "$php")/php-config"
    if [ -x "$pc" ]; then
        line="$("$pc" --configure-options 2>/dev/null)"
        how="$pc --configure-options"
    fi
fi
[ -n "$line" ] || { echo "config-check: no configure options from $php (php -i failed, no php-config)" >&2; exit 2; }
to_lines "$line" "$how" > "$tmp/installed_order"
LC_ALL=C sort -u "$tmp/installed_order" > "$tmp/installed"
version="$("$php" -n -v 2>/dev/null | head -1)"
ver="$(printf '%s\n' "$version" | awk '{print $2}')"

# The old build's config.nice: given, ./config.nice, or found next to this tree.
found=""
if [ -z "$nice" ]; then
    if [ -r ./config.nice ]; then
        nice=./config.nice
    elif [ -n "$ver" ]; then
        here="$(pwd)"
        for d in .. "${HOME:-/root}"; do
            [ -d "$d" ] || continue
            for f in "$d/php-$ver/config.nice" "$d/php-$ver"-*/config.nice; do
                [ -r "$f" ] || continue
                [ "$(cd "$(dirname "$f")" && pwd)" = "$here" ] && continue
                printf '%s\n' "$f"
            done
        done > "$tmp/candidates"
        if [ -s "$tmp/candidates" ]; then
            # newest first; the list has no spaces in practice (php-<version>* names)
            # shellcheck disable=SC2046
            nice="$(ls -t $(cat "$tmp/candidates") | head -1)"
            found=" (newest config.nice of PHP $ver found here; give another one as the second argument)"
        fi
    fi
fi
if [ -n "$nice" ] && [ ! -r "$nice" ]; then
    echo "config-check: cannot read $nice" >&2
    exit 2
fi

# config.nice: NAME='value' lines before the configure line are environment
# settings; everything from the configure line on (continuation lines joined)
# holds the configure path and its options.
: > "$tmp/env"
: > "$tmp/nice"
if [ -n "$nice" ]; then
    awk -v q="'" '
        { sub(/[[:space:]]*\\$/, "") }
        !opts && /^[A-Za-z_][A-Za-z0-9_]*=/ { print > ENVF; next }
        !opts && substr($0, 1, 1) == q { opts = 1 }
        opts && $0 != "\"$@\"" { printf "%s ", $0 > ARGF }
    ' ENVF="$tmp/env" ARGF="$tmp/nice_args" "$nice"
    if [ -f "$tmp/nice_args" ]; then
        to_lines "$(cat "$tmp/nice_args")" "$nice" | LC_ALL=C sort -u > "$tmp/nice"
    fi
    [ -s "$tmp/nice" ] || { echo "config-check: no configure options found in $nice" >&2; exit 2; }
fi

printf 'installed:   %s\n             %s\n             %s options, from %s\n' \
    "$php" "${version:-?}" "$(wc -l < "$tmp/installed" | tr -d ' ')" "$how"
if [ -n "$nice" ]; then
    printf 'config.nice: %s%s\n             %s options\n' "$nice" "$found" "$(wc -l < "$tmp/nice" | tr -d ' ')"
else
    printf 'config.nice: none found (no ./config.nice, no php-%s/config.nice next to this tree or in %s)\n' \
        "${ver:-?}" "${HOME:-/root}"
fi

LC_ALL=C comm -23 "$tmp/installed" "$tmp/nice" > "$tmp/only_installed"
LC_ALL=C comm -13 "$tmp/installed" "$tmp/nice" > "$tmp/only_nice"
if [ -s "$tmp/env" ]; then
    echo
    echo "environment in config.nice (not recorded by the installed build, not compared):"
    sed 's/^/  /' "$tmp/env"
fi
if [ -n "$nice" ] && [ -s "$tmp/only_installed" ]; then
    echo
    echo "only in the installed build (missing in config.nice):"
    sed 's/^/  /' "$tmp/only_installed"
fi
if [ -s "$tmp/only_nice" ]; then
    echo
    echo "only in config.nice (the installed build was built without them):"
    sed 's/^/  /' "$tmp/only_nice"
fi

# The script with the installed build's options, in the order the build recorded.
out_dir="$(cd "$(dirname "$out")" 2>/dev/null && pwd)" || { echo "config-check: no directory for $out" >&2; exit 2; }
out_name="$(basename "$out")"
out="$out_dir/$out_name"
{
    echo "#!/bin/sh"
    echo "# Written by config-check.sh on $(date '+%d.%m.%Y %H:%M'): the configure options of"
    echo "# $php (${version:-?}), from $how."
    if [ -s "$tmp/env" ]; then
        echo "# The environment lines come from $nice (the installed build does not record them)."
    fi
    echo "# Run from inside the new PHP source tree: sh $out"
    echo
    sed 's/$/ \\/' "$tmp/env"
    echo "'./configure' \\"
    sed "s/'/'\\\\''/g; s/^/'/; s/\$/' \\\\/" "$tmp/installed_order"
    echo '"$@"'
} > "$out" || { echo "config-check: cannot write $out" >&2; exit 2; }
chmod +x "$out" 2>/dev/null || true

echo
if [ -z "$nice" ]; then
    echo "RESULT: nothing to compare with; written from the installed build alone."
    echo "        CFLAGS and other environment settings are not recorded by the installed"
    echo "        build: give the old config.nice as the second argument to carry them over."
    rc=1
elif [ ! -s "$tmp/only_installed" ] && [ ! -s "$tmp/only_nice" ]; then
    echo "RESULT: same options; config.nice matches the installed build."
    rc=0
else
    echo "RESULT: different; the installed build wins."
    rc=1
fi
echo "written: $out"
echo "next, from inside the new source tree: sh $out"
exit "$rc"
