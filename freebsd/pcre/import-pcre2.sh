#!/bin/sh
# import-pcre2.sh <php source tree> <unpacked pcre2 release> - replace the PCRE2
# that PHP bundles (ext/pcre/pcre2lib) with that release, as php-src imports it:
# the library sources of src/ (COMMON_SOURCES of Makefile.am), pcre2.h from
# pcre2.h.generic, pcre2_chartables.c from pcre2_chartables.c.dist and sljit
# (deps/sljit/sljit_src in 10.45 and later, src/sljit before) in pcre2lib/sljit.
# PHP's own pcre2lib/config.h stays, with the defaults of the release's
# config.h.generic it lacks. The list of compilation units in ext/pcre/config0.m4
# becomes that of the release (7.4-8.3: the pcrelib_sources string, 8.4: the
# m4_normalize list). main/php_compat.h renames every function of the bundled
# library to php_pcre2_* (php-src's list misses the functions added since
# 10.30), so that a PCRE2 library loaded in the same process (Apache's, for
# mod_php) takes none of the calls of the bundled one. tools/sync.sh runs it for
# the targets of freebsd/pcre.conf (Windows' config.w32 is left as it is).
set -eu
[ $# -eq 2 ] || { echo "usage: import-pcre2.sh <php source tree> <pcre2 release dir>" >&2; exit 2; }
tree="$1"
rel="$2"
lib="$tree/ext/pcre/pcre2lib"
m4="$tree/ext/pcre/config0.m4"
[ -f "$lib/config.h" ] && [ -f "$m4" ] || { echo "import-pcre2: no ext/pcre/pcre2lib/config.h in $tree" >&2; exit 2; }
[ -f "$rel/Makefile.am" ] && [ -f "$rel/src/pcre2.h.generic" ] || { echo "import-pcre2: $rel is not a PCRE2 release" >&2; exit 2; }

srcs="$(sed -n '/^COMMON_SOURCES = /,/^$/p' "$rel/Makefile.am" | grep -o 'src/[a-z0-9_]*\.[ch]' | sed 's#^src/##')"
units="pcre2_chartables.c $(printf '%s\n' "$srcs" | grep '\.c$' | tr '\n' ' ')"
[ -n "$srcs" ] || { echo "import-pcre2: no COMMON_SOURCES in $rel/Makefile.am" >&2; exit 2; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp "$lib/config.h" "$tmp/config.h"
rm -rf "$lib"
mkdir "$lib"
for f in $srcs; do
    cp "$rel/src/$f" "$lib/$f"
done
cp "$rel/src/pcre2.h.generic" "$lib/pcre2.h"
cp "$rel/src/pcre2_chartables.c.dist" "$lib/pcre2_chartables.c"
if [ -d "$rel/deps/sljit/sljit_src" ]; then
    sj="$rel/deps/sljit/sljit_src"
else
    sj="$rel/src/sljit"
fi
mkdir "$lib/sljit"
cp -R "$sj"/. "$lib/sljit/"
sed 's#"\.\./deps/sljit/sljit_src/#"sljit/#' "$lib/pcre2_jit_compile.c" > "$tmp/jit.c"
cp "$tmp/jit.c" "$lib/pcre2_jit_compile.c"
cp "$tmp/config.h" "$lib/config.h"
# defaults of the release's config.h.generic (#ifndef NAME / #define NAME / #endif)
# that PHP's config.h, made for an older PCRE2, lacks: MAX_VARLOOKBEHIND (10.43)
# for 7.4-8.3; and PCRE2_EXPORT, which pcre2_internal.h uses (not those of
# libtool and pcre2grep)
awk -v have="$lib/config.h" '
    BEGIN { while ((getline l < have) > 0) php = php "\n" l; php = php "\n" }
    function known(n) { return php ~ ("[^A-Za-z0-9_]" n "[^A-Za-z0-9_]") }
    /^\/\*/ { com = $0; incom = ($0 !~ /\*\//); next }
    incom { com = com "\n" $0; if ($0 ~ /\*\//) incom = 0; next }
    /^#ifndef [A-Z_0-9]+[[:space:]]*$/ {
        name = $2; blk = $0; getline d; getline e
        if (d ~ ("^#define " name "([[:space:]]|$)") && e ~ /^#endif/ && !known(name) && name !~ /^(LT_|PCRE2GREP)/)
            printf "\n%s\n%s\n%s\n%s\n", com, blk, d, e
        com = ""; next
    }
    /^$/ { next }
    { com = "" }
    END {
        if (!known("PCRE2_EXPORT"))
            printf "\n/* to make a symbol visible */\n#ifndef PCRE2_EXPORT\n#define PCRE2_EXPORT\n#endif\n"
    }
' "$rel/src/config.h.generic" > "$tmp/add.h"
if [ -s "$tmp/add.h" ]; then
    cat "$tmp/add.h" >> "$lib/config.h"
    echo "import-pcre2: added to config.h: $(grep '^#ifndef' "$tmp/add.h" | awk '{print $2}' | tr '\n' ' ')"
fi

# the compilation units in config0.m4
awk -v units="$units" '
    function emit_string(   n, a, i, s) {
        n = split(units, a, " "); s = ""
        for (i = 1; i <= n; i++) s = s (i > 1 ? " " : "") "pcre2lib/" a[i]
        print "  pcrelib_sources=\"" s "\""
    }
    function emit_lines(ind,   n, a, i) {
        n = split(units, a, " ")
        for (i = 1; i <= n; i++) print ind "pcre2lib/" a[i]
    }
    done { print; next }
    !skip && /pcrelib_sources="pcre2lib\// { skip = 1; style = "string" }
    !skip && style == "" && /^[[:space:]]*pcre2lib\/pcre2_[a-z0-9_]*\.c[[:space:]]*$/ {
        style = "lines"; ind = $0; sub(/pcre2lib.*/, "", ind); skip = 1
    }
    skip && style == "string" {
        if ($0 ~ /\.c"[[:space:]]*$/) { emit_string(); skip = 0; done = 1 }
        next
    }
    skip && style == "lines" {
        if ($0 ~ /^[[:space:]]*pcre2lib\/pcre2_[a-z0-9_]*\.c[[:space:]]*$/) next
        emit_lines(ind); skip = 0; done = 1; print; next
    }
    { print }
    END { if (!done) exit 1 }
' "$m4" > "$tmp/config0.m4" || { echo "import-pcre2: no list of pcre2lib sources in $m4" >&2; exit 1; }
cp "$tmp/config0.m4" "$m4"

# the functions of the release's pcre2.h that main/php_compat.h does not rename
compat="$tree/main/php_compat.h"
tr '\n' ' ' < "$lib/pcre2.h" | grep -o 'PCRE2_CALL_CONVENTION[ \\]*pcre2_[a-z0-9_]*(' |
    sed 's/.*\(pcre2_[a-z0-9_]*\)($/\1/' | sort -u > "$tmp/functions"
[ -s "$tmp/functions" ] || { echo "import-pcre2: no functions found in $lib/pcre2.h" >&2; exit 1; }
: > "$tmp/renames"
while read -r f; do
    grep -q "^#define ${f}_8[[:space:]]" "$compat" || printf '#define %s_8 php_%s\n' "$f" "$f" >> "$tmp/renames"
done < "$tmp/functions"
if [ -s "$tmp/renames" ]; then
    awk -v add="$tmp/renames" '
        { line[NR] = $0 }
        /^#define pcre2_[a-z0-9_]*_8[[:space:]]+php_pcre2_/ { last = NR }
        END {
            if (!last) exit 1
            for (i = 1; i <= NR; i++) {
                print line[i]
                if (i == last) while ((getline l < add) > 0) print l
            }
        }
    ' "$compat" > "$tmp/php_compat.h" || { echo "import-pcre2: no php_pcre2_ renames in $compat" >&2; exit 1; }
    cp "$tmp/php_compat.h" "$compat"
    echo "import-pcre2: renamed in main/php_compat.h: $(sed 's/^#define \([a-z0-9_]*\)_8 .*/\1/' "$tmp/renames" | tr '\n' ' ')"
fi
v="$(sed -n 's/^#define PCRE2_MAJOR *\([0-9]*\).*/\1/p; s/^#define PCRE2_MINOR *\([0-9]*\).*/.\1/p' "$lib/pcre2.h" | tr -d '\n')"
echo "import-pcre2: ext/pcre/pcre2lib is PCRE2 $v ($(printf '%s\n' $units | wc -l | tr -d ' ') units)"
