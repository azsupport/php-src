#!/bin/sh
# collect-options.sh - write down what every PHP of this server was built with,
# for a review of the ./configure options across the servers.
#
# For each hand-built PHP (/usr/local/php*/bin/php, else sbin/php-fpm or
# bin/php-cgi) and the PHP of the packages (/usr/local/bin/php): its version, the
# configure options it records (Configure Command of "php -n -i"; php-config
# --configure-options when the binary does not run - that one prints them
# without quotes), "php -m", the php.ini files it loads, and the config.nice
# files of the source trees of that version in /root, as they are. Also the
# CPUTYPE/CFLAGS lines of /etc/make.conf, the Apache version and the PHP
# packages. Read-only: it changes nothing and needs no network.
#
# Usage (FreeBSD /bin/sh; from csh run it with sh):
#   sh collect-options.sh            writes ./php-options-<host>.txt
#   OUT=- sh collect-options.sh      prints to stdout instead
# PHP_DIRS (default: /usr/local/php* /usr/local) and SRC_DIRS (default: /root)
# override where it looks.

set -u
host="$(hostname -s 2>/dev/null || hostname)"
out="${OUT:-./php-options-$host.txt}"
php_dirs="${PHP_DIRS:-/usr/local/php* /usr/local}"
src_dirs="${SRC_DIRS:-/root}"

# modification time of a file (FreeBSD stat, else GNU date)
mtime() {
    case "$(uname -s)" in
        FreeBSD) stat -f '%Sm' -t '%d.%m.%Y %H:%M' "$1" 2>/dev/null ;;
        *) date -r "$1" '+%d.%m.%Y %H:%M' 2>/dev/null ;;
    esac
}

one_php() {
    bin="$1"
    echo
    echo "=== $bin"
    v="$("$bin" -n -v 2>&1 | head -n 1)"
    if "$bin" -n -v > /dev/null 2>&1; then
        echo "version: $v"
        runs=1
    else
        echo "version: ? (the binary does not run: $v)"
        runs=""
    fi
    pc="$(dirname "$bin")/php-config"
    cc=""
    [ -n "$runs" ] && cc="$("$bin" -n -i 2>/dev/null | sed -n 's/^Configure Command =>[[:space:]]*//p' | head -n 1)"
    if [ -n "$cc" ]; then
        echo "configure (php -n -i): $cc"
    elif [ -x "$pc" ]; then
        echo "configure (php-config, quotes removed): $("$pc" --configure-options 2>/dev/null)"
    else
        echo "configure: ? (no Configure Command and no php-config)"
    fi
    [ -x "$pc" ] && echo "php-config version: $("$pc" --version 2>/dev/null)"
    if [ -n "$runs" ]; then
        echo "modules (php -m): $("$bin" -m 2>/dev/null | grep -v -e '^\[' -e '^$' | tr '\n' ' ' | sed 's/ *$//')"
        echo "ini (php --ini):"
        "$bin" --ini 2>/dev/null | grep -v '^$' | sed 's/^/  /'
    else
        # what its php.ini files would load, as far as they can be found
        ext="$(for f in "$(dirname "$bin")"/../etc/php*.ini /usr/local/etc/php*.ini; do
            [ -r "$f" ] || continue
            awk -v f="$f" '/^[[:space:]]*(zend_)?extension[[:space:]]*=/ { sub(/^[[:space:]]+/, ""); print "  " f ": " $0 }' "$f"
        done)"
        if [ -n "$ext" ]; then
            echo "extension lines of php.ini files (php -m cannot run):"
            printf '%s\n' "$ext"
        fi
    fi
    ver="$(printf '%s\n' "$v" | awk '$1 == "PHP" { print $2 }')"
    [ -n "$ver" ] || ver="$("$pc" --version 2>/dev/null)"
    [ -n "$ver" ] || return 0
    for d in $src_dirs; do
        for f in "$d/php-$ver/config.nice" "$d/php-$ver"-*/config.nice; do
            [ -r "$f" ] || continue
            echo "--- $f ($(mtime "$f"))"
            cat "$f"
        done
    done
}

collect() {
    echo "# PHP build options of $host, $(date '+%d.%m.%Y %H:%M')"
    echo "uname: $(uname -srm)"
    [ -r /etc/make.conf ] &&
        grep -E '^[[:space:]]*(CPUTYPE|CFLAGS|CXXFLAGS)[[:space:]]*[?:+]?=' /etc/make.conf | sed 's/^/make.conf: /'
    [ -x /usr/local/sbin/httpd ] && echo "apache: $(/usr/local/sbin/httpd -v 2>/dev/null | head -n 1)"
    if command -v pkg > /dev/null 2>&1; then
        pkg query '%n %v' 2>/dev/null | grep -E '^(mod_)?php[0-9]+(-[^ ]+)? ' | sed 's/^/pkg: /'
    fi
    # shellcheck disable=SC2086
    for d in $php_dirs; do
        [ -d "$d" ] || continue
        for c in bin/php sbin/php-fpm bin/php-cgi; do
            if [ -x "$d/$c" ] && [ -f "$d/$c" ]; then
                one_php "$d/$c"
                break
            fi
        done
    done
}

if [ "$out" = - ]; then
    collect
else
    collect > "$out" || { echo "collect-options: cannot write $out" >&2; exit 2; }
    echo "written: $out"
fi
