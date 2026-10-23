#!/bin/sh
# import-pcre1.sh <php 5.6 source tree> <PCRE 8.x source> - replace the PCRE that
# PHP 5.6 bundles (ext/pcre/pcrelib, 8.38) with that source: the same files PHP
# keeps there (the library sources, headers, sljit/, the docs and testdata), from
# the source tree (a release, or the PCRE2Project/pcre1 repository); pcre.h is
# made from pcre.h.in (version and date of configure.ac), pcre_chartables.c is
# pcre_chartables.c.dist. PHP's own pcrelib/config.h stays, and so does the list
# of compilation units in ext/pcre/config0.m4 (the same files). main/php_compat.h
# renames every public name of the library to php_pcre_* (PHP's list misses the
# JIT functions, pcre_free_study, pcre_dfa_exec, pcre_stack_guard and others),
# so that a PCRE library loaded in the same process takes none of the calls of
# the bundled one. tools/sync.sh runs it for the 5.6 line of freebsd/pcre.conf.
set -eu
[ $# -eq 2 ] || { echo "usage: import-pcre1.sh <php 5.6 source tree> <pcre 8.x source>" >&2; exit 2; }
tree="$1"
src="$2"
lib="$tree/ext/pcre/pcrelib"
[ -f "$lib/config.h" ] || { echo "import-pcre1: no ext/pcre/pcrelib/config.h in $tree" >&2; exit 2; }
[ -f "$src/pcre.h.in" ] && [ -f "$src/configure.ac" ] || { echo "import-pcre1: $src is not a PCRE 8.x source" >&2; exit 2; }
maj="$(sed -n 's/^m4_define(pcre_major, \[\([0-9]*\)\])/\1/p' "$src/configure.ac")"
min="$(sed -n 's/^m4_define(pcre_minor, \[\([0-9]*\)\])/\1/p' "$src/configure.ac")"
pre="$(sed -n 's/^m4_define(pcre_prerelease, \[\(.*\)\])/\1/p' "$src/configure.ac")"
day="$(sed -n 's/^m4_define(pcre_date, \[\(.*\)\])/\1/p' "$src/configure.ac")"
[ -n "$maj" ] && [ -n "$min" ] && [ -n "$day" ] || { echo "import-pcre1: no version in $src/configure.ac" >&2; exit 2; }

missing=""
for f in $(cd "$lib" && find . -type f | sed 's#^\./##'); do
    case "$f" in
        config.h|*.o|*.lo|*.dep|*/.libs/*|.libs/*) continue ;;
        pcre.h)
            sed -e "s/@PCRE_MAJOR@/$maj/" -e "s/@PCRE_MINOR@/$min/" -e "s/@PCRE_PRERELEASE@/$pre/" \
                -e "s/@PCRE_DATE@/$day/" "$src/pcre.h.in" > "$lib/pcre.h"
            continue ;;
        pcre_chartables.c) cp "$src/pcre_chartables.c.dist" "$lib/$f"; continue ;;
    esac
    if [ -f "$src/$f" ]; then
        cp "$src/$f" "$lib/$f"
    else
        missing="$missing $f"
    fi
done
# files of the new sljit that the old one had not
for f in "$src"/sljit/*; do
    [ -f "$f" ] && cp "$f" "$lib/sljit/"
done
if grep -q '@' "$lib/pcre.h" && grep -n '@[A-Za-z_]*@' "$lib/pcre.h" >&2; then
    echo "import-pcre1: placeholders left in pcre.h" >&2
    exit 1
fi
[ -z "$missing" ] || echo "import-pcre1: kept from the old PCRE (not in $src):$missing" >&2

# the public names of pcre.h (functions and the pcre_malloc-style pointers) that
# main/php_compat.h does not rename
compat="$tree/main/php_compat.h"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
tr '\n' ' ' < "$lib/pcre.h" | grep -o 'PCRE_EXP_DECL[^;]*;' | grep -o 'pcre_[a-z0-9_]*)\{0,1\}[[:space:]]*(' |
    sed 's/[)[:space:]]*($//' | sort -u > "$tmp/names"
[ -s "$tmp/names" ] || { echo "import-pcre1: no functions found in $lib/pcre.h" >&2; exit 1; }
: > "$tmp/renames"
while read -r f; do
    grep -q "^#define $f[[:space:]]" "$compat" || printf '#define %s\t\t\tphp_%s\n' "$f" "$f" >> "$tmp/renames"
done < "$tmp/names"
if [ -s "$tmp/renames" ]; then
    awk -v add="$tmp/renames" '
        { line[NR] = $0 }
        /^#define _?pcre_[A-Za-z0-9_]*[[:space:]]+php__?pcre_/ { last = NR }
        END {
            if (!last) exit 1
            for (i = 1; i <= NR; i++) {
                print line[i]
                if (i == last) while ((getline l < add) > 0) print l
            }
        }
    ' "$compat" > "$tmp/php_compat.h" || { echo "import-pcre1: no php_pcre_ renames in $compat" >&2; exit 1; }
    cp "$tmp/php_compat.h" "$compat"
    echo "import-pcre1: renamed in main/php_compat.h: $(awk '{print $2}' "$tmp/renames" | tr '\n' ' ')"
fi
echo "import-pcre1: ext/pcre/pcrelib is PCRE $maj.$min ($day)"
