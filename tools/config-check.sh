#!/bin/sh
# config-check.sh - before reusing a config.nice for a rebuild, compare its
# ./configure options with those of the PHP build that is actually installed.
# The installed build wins: when the options differ, a config script with the
# installed build's options is written to the current directory.
#
# Usage (FreeBSD /bin/sh; from csh run it with sh):
#   sh config-check.sh /usr/local/php81 /root/php-8.1.34/config.nice
#   sh config-check.sh /usr/local/php81/bin/php          # uses ./config.nice
#
#   The first argument is a php, php-fpm or php-cgi binary, or an install prefix
#   (bin/php, sbin/php-fpm or bin/php-cgi inside it is used).
#   OUT=/path/file.sh overrides where the script with the installed options goes
#   (default: ./config.installed.sh).
#
# The installed options come from "<binary> -n -i" (Configure Command; -n skips
# php.ini, so a broken shared extension does not get in the way) or, failing that,
# from php-config --configure-options next to the binary. Environment lines of
# config.nice (CFLAGS=... and the like) are shown and carried over, but not
# compared: the installed build does not record them.
#
# Exit status: 0 same options, 1 different (script written), 2 usage or read error.

set -u

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    sed -n 's/^# \{0,1\}//; 7,9p' "$0" >&2
    exit 2
fi
target="$1"
nice="${2:-./config.nice}"
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
[ -r "$nice" ] || { echo "config-check: cannot read $nice" >&2; exit 2; }

tmp="$(mktemp -d)" || exit 2
trap 'rm -rf "$tmp"' EXIT INT TERM

# One option per line, without quotes and without the ./configure path itself.
to_lines() {
    case "$1" in
        *\'*) printf '%s\n' "$1" | grep -o "'[^']*'" | sed "s/^'//; s/'\$//" ;;
        *) printf '%s\n' "$1" | tr -s '[:blank:]' '\n' ;;
    esac | grep -v -e '^$' -e '^[^-].*configure$'
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
to_lines "$line" | LC_ALL=C sort -u > "$tmp/installed"
version="$("$php" -n -v 2>/dev/null | head -1)"

# config.nice: quoted lines ending in " \" are the configure path and its options,
# NAME='value' lines before them are environment settings.
awk -v q="'" '
    { sub(/[[:space:]]*\\$/, "") }
    /^[A-Za-z_][A-Za-z0-9_]*=/ { print > ENVF; next }
    substr($0, 1, 1) == q && substr($0, length($0), 1) == q { print substr($0, 2, length($0) - 2) }
' ENVF="$tmp/env" "$nice" | grep -v -e '^$' -e '^[^-].*configure$' | LC_ALL=C sort -u > "$tmp/nice"
[ -f "$tmp/env" ] || : > "$tmp/env"
[ -s "$tmp/nice" ] || { echo "config-check: no configure options found in $nice" >&2; exit 2; }

printf 'installed:   %s\n             %s\n             %s options, from %s\n' \
    "$php" "${version:-?}" "$(wc -l < "$tmp/installed" | tr -d ' ')" "$how"
printf 'config.nice: %s\n             %s options\n' "$nice" "$(wc -l < "$tmp/nice" | tr -d ' ')"

LC_ALL=C comm -23 "$tmp/installed" "$tmp/nice" > "$tmp/only_installed"
LC_ALL=C comm -13 "$tmp/installed" "$tmp/nice" > "$tmp/only_nice"
if [ -s "$tmp/env" ]; then
    echo
    echo "environment in config.nice (not recorded by the installed build, not compared):"
    sed 's/^/  /' "$tmp/env"
fi
if [ ! -s "$tmp/only_installed" ] && [ ! -s "$tmp/only_nice" ]; then
    echo
    echo "RESULT: same options; config.nice reproduces the installed build."
    exit 0
fi
if [ -s "$tmp/only_installed" ]; then
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
    to_lines "$line" | sed "s/'/'\\\\''/g; s/^/'/; s/\$/' \\\\/"
    echo '"$@"'
} > "$out" || { echo "config-check: cannot write $out" >&2; exit 2; }
chmod +x "$out" 2>/dev/null || true

echo
echo "RESULT: different. The installed build wins; written: $out"
echo "  run it instead of config.nice from inside the new source tree: sh $out"
exit 1
