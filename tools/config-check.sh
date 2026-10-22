#!/bin/sh
# config-check.sh - before reusing a config.nice for a rebuild, compare its
# ./configure options with those of the PHP build that is actually installed.
# The installed build wins: a config script with the installed build's options,
# config.installed.sh, is always written to the current directory; run that one.
#
# Usage (FreeBSD /bin/sh; from csh run it with sh):
#   sh config-check.sh /usr/local/php81
#   sh config-check.sh /usr/local/php81 /root/php-8.1.34/config.nice
#   sh config-check.sh --pkg [php74]
#
#   The first argument is the install directory of the hand-built PHP (its bin/php,
#   or else sbin/php-fpm or bin/php-cgi is used), or one of those binaries.
#   --pkg instead writes the options for a hand build that replaces the PHP
#   installed as packages (lang/phpXY, phpXY-* extensions, mod_phpXY): the port
#   options of phpXY, one option per extension package (for the bundled PECL ones
#   with the features "php --ri" of the package PHP shows: lz4/zstd of redis, SASL
#   and JSON of memcached, ...), the layout of our hand builds (/usr/local/phpXY)
#   and CFLAGS from /etc/make.conf (CFLAGS, CPUTYPE).
#   With mod_phpXY installed the build makes the Apache module; the EMBED option
#   of phpXY (the embed library, a second SAPI module, which one build cannot make
#   as well) is left out, the report says whether a package uses that library.
#   The second argument is the config.nice of the old build. Without it,
#   ./config.nice is used, or else the newest php-<version>/config.nice or
#   php-<version>-*/config.nice next to the current directory or in $HOME, where
#   <version> is the installed version (php-8.1.34, php-8.1.34-fbsd-20261021-...).
#   Run it from inside the new PHP source tree, then: sh config.installed.sh
#   OUT=/path/file.sh overrides where the script goes (default: ./config.installed.sh).
#
# The installed options come from "<binary> -n -i" (Configure Command; -n skips
# php.ini, so a broken shared extension does not get in the way) or, failing that,
# from php-config --configure-options next to the binary. When the binary does not
# run either way (a library it links against was removed or upgraded, a crash),
# the options of the config.nice (given or found) are taken instead, as they are,
# and the report says why the installed build could not be read; its shared PECL
# modules are then those of the extension= lines of its php.ini, looked for at
# --with-config-file-path and --with-config-file-scan-dir, <prefix>/etc/php*.ini,
# /usr/local/etc/phpXY.ini and the Apache PHPIniDir that names it. Environment lines of
# config.nice (CFLAGS=... and the like) are shown and carried over, but not
# compared: the installed build does not record them. PHP 5.6 records options with
# spaces in a broken quoting ('CFLAGS=-O3 '-pipe' '-march=...''); both sources are
# split the way the shell would, so such an option stays one option.
# Without a config.nice the environment comes from /etc/make.conf, as for the
# ports: its CFLAGS, -march=$CPUTYPE, LIBS=-lpthread (LINKTHR of lang/phpXY).
# In both modes the -march is the one of /etc/make.conf of this server (CPUTYPE,
# or a -march= in its CFLAGS), so a config.nice from a server with another CPU
# does not bring its -march along; a -march that needs CPU features this CPU has
# not (cc -march=native) gives a warning, PHP built with it would stop with
# "Illegal instruction".
# Where the source tree bundles curl (ext/curl/libcurl) and the build's OpenSSL is
# 3.0 or later, --with-curl becomes --with-curl=bundled (curl built into PHP); with
# OpenSSL 1.1.1 (FreeBSD 13.x base) the libcurl of pkg stays, the report says why.
# --with-openssl=<dir> loses its directory for PHP 7.4 and later, whose configure
# ignores it (pkg-config finds OpenSSL); for PHP 5.6 a directory that has no
# OpenSSL headers any more (security/openssl removed) becomes /usr, the base system.
# A build against OpenSSL 3 gets --with-openssl-legacy-provider when the installed
# PHP can do RC4, and always for PHP 5.6 and 7.4, so that RC4, Blowfish, DES and the
# like keep working; the report says so.
# Shared PECL modules that the source tree bundles (redis, memcached, memcache,
# imagick, gmagick, igbinary, swoole, openswoole, excimer, mcrypt) are not added to
# the script: the report ends with the command that builds them in, with the
# features they were built with (php --ri), and lists the extension= lines to
# remove after make install.
#
# Exit status: 0 same options, 1 different (or no config.nice to compare with),
# 2 usage or read error.

set -u
out="${OUT:-./config.installed.sh}"
mk_conf="${MAKE_CONF:-/etc/make.conf}"

# A variable of make.conf (VAR=, ?=, := and += lines; comments dropped).
mc_get() {
    [ -r "$mk_conf" ] || return 0
    awk -v v="$1" '
        { sub(/#.*/, "") }
        $0 ~ "^[ \t]*" v "[ \t]*[?:]?=" { s = $0; sub("^[ \t]*" v "[ \t]*[?:]?=[ \t]*", "", s); val = s; have = 1; next }
        $0 ~ "^[ \t]*" v "[ \t]*\\+=" { s = $0; sub("^[ \t]*" v "[ \t]*\\+=[ \t]*", "", s); val = val " " s; have = 1 }
        END { if (have) { sub(/[ \t]+$/, "", val); print val } }
    ' "$mk_conf"
}

# CFLAGS as the ports build with them on this server: CFLAGS of make.conf (or
# -O2 -pipe), -march=$CPUTYPE, and the ports' -fstack-protector-strong and
# -fno-strict-aliasing.
mc_cflags() {
    c="$(mc_get CFLAGS)"
    t="$(mc_get CPUTYPE)"
    printf '%s' "${c:--O2 -pipe}${t:+ -march=$t} -fstack-protector-strong -fno-strict-aliasing"
}

# The -march of this server: CPUTYPE of make.conf, else a -march= in its CFLAGS.
mc_march() {
    t="$(mc_get CPUTYPE)"
    [ -n "$t" ] || t="$(mc_get CFLAGS | tr -s ' \t' '\n\n' | sed -n 's/^-march=//p' | tail -n 1)"
    printf '%s' "$t"
}

# The -march= values in CFLAGS/CXXFLAGS lines of the given files.
march_in() {
    cat "$@" 2>/dev/null | grep -E "^'?C(XX)?FLAGS=" | tr -s " '\"" '\n\n\n' |
        sed -n 's/^-march=//p' | sort -u | tr '\n' ' ' | sed 's/ *$//'
}

# The CPU features that -march=$1 turns on and this CPU has not (by the compiler's
# -march=native): PHP built with them stops with "Illegal instruction" here.
cpu_lacks() {
    feats() {
        "${CC:-cc}" "-march=$1" -dM -E - < /dev/null 2>/dev/null |
            sed -n -E 's/^#define __(SSE4_2|POPCNT|AVX|AVX2|BMI|BMI2|FMA|F16C|LZCNT|MOVBE|AVX512F|AVX512BW|AVX512CD|AVX512DQ|AVX512VL)__ 1$/\1/p' |
            LC_ALL=C sort -u
    }
    [ -n "$1" ] && [ "$1" != native ] || return 0
    feats "$1" > "$tmp/cpu_need"
    feats native > "$tmp/cpu_have"
    [ -s "$tmp/cpu_need" ] && [ -s "$tmp/cpu_have" ] || return 0
    LC_ALL=C comm -23 "$tmp/cpu_need" "$tmp/cpu_have" | tr '\n' ' ' | sed 's/ *$//'
}

# The include directory of the OpenSSL a build takes, as its configure and
# ext/curl/build-libcurl.sh find it: PHP 5.6 ($3 = 5) the dir of
# --with-openssl=<dir> ($1); PHP 7.4 and later the -I of OPENSSL_CFLAGS or
# PKG_CONFIG_PATH in the environment lines of file $2 and pkg-config; else the
# base system.
ossl_incdir() {
    # with /usr/local/phpdeps installed, its OpenSSL (see deps_opts)
    if [ -f "${PHPDEPS:-/usr/local/phpdeps}/VERSIONS" ] && [ -x "${PHPDEPS:-/usr/local/phpdeps}/bin/pkg-config" ]; then
        echo "${PHPDEPS:-/usr/local/phpdeps}/include"; return
    fi
    if [ "${3:-}" = 5 ]; then
        case "${1:-}" in /*) echo "$1/include"; return ;; esac
    fi
    i="$(sed -n "s/^OPENSSL_CFLAGS='\{0,1\}\([^']*\)'\{0,1\} *\\\\\{0,1\}\$/\1/p" "$2" 2>/dev/null | head -n 1 |
        tr ' ' '\n' | sed -n 's/^-I//p' | head -n 1)"
    if [ -n "$i" ]; then echo "$i"; return; fi
    p="$(sed -n "s/^PKG_CONFIG_PATH='\{0,1\}\([^']*\)'\{0,1\} *\\\\\{0,1\}\$/\1/p" "$2" 2>/dev/null | head -n 1)"
    i="$(PKG_CONFIG_PATH="${p:-${PKG_CONFIG_PATH:-}}" pkg-config --variable=includedir openssl 2>/dev/null)"
    echo "${i:-/usr/include}"
}
ossl_text() { sed -n 's/.*OPENSSL_VERSION_TEXT *"\([^"]*\)".*/\1/p' "$1/openssl/opensslv.h" 2>/dev/null | head -n 1; }

# --with-openssl=<dir> of the script: PHP 7.4 and later ignore the directory
# (pkg-config, or OPENSSL_CFLAGS and OPENSSL_LIBS, find OpenSSL), so the option
# goes without it, and OPENSSL_CFLAGS/OPENSSL_LIBS lines whose -I directory has no
# OpenSSL headers any more are dropped; PHP 5.6 takes the directory, which becomes
# /usr (the base system) when it has no OpenSSL headers any more (security/openssl
# removed). $1: options, $2: environment lines (both changed in place). Sets ossl_note.
ossl_note=""
ossl_opts() {
    pmaj="$(sed -n 's/^#define PHP_MAJOR_VERSION \([0-9]*\).*/\1/p' main/php_version.h 2>/dev/null)"
    pmin="$(sed -n 's/^#define PHP_MINOR_VERSION \([0-9]*\).*/\1/p' main/php_version.h 2>/dev/null)"
    [ -n "$pmaj" ] || return 0
    if [ "$pmaj" != 5 ]; then
        i="$(sed -n "s/^OPENSSL_CFLAGS='\{0,1\}\([^']*\)'\{0,1\}\$/\1/p" "$2" 2>/dev/null | head -n 1 |
            tr ' ' '\n' | sed -n 's/^-I//p' | head -n 1)"
        if [ -n "$i" ] && [ ! -f "$i/openssl/opensslv.h" ]; then
            grep -v -e '^OPENSSL_CFLAGS=' -e '^OPENSSL_LIBS=' "$2" > "$2.new" && mv "$2.new" "$2"
            ossl_note="OPENSSL_CFLAGS and OPENSSL_LIBS dropped: $i has no OpenSSL headers any more"
        fi
    fi
    o="$(grep -E -m 1 '^--with-openssl=' "$1")" || return 0
    v="${o#--with-openssl=}"
    sh=""
    case "$v" in
        shared) return 0 ;;
        shared,*) sh="shared,"; v="${v#shared,}" ;;
    esac
    if [ "$pmaj" = 5 ]; then
        [ -f "$v/include/openssl/opensslv.h" ] && return 0
        [ -f /usr/include/openssl/opensslv.h ] || return 0
        n="--with-openssl=${sh}/usr"
        why="$v has no OpenSSL headers any more, the base system has $(ossl_text /usr/include)"
    else
        n="--with-openssl${sh:+=shared}"
        inc="$(ossl_incdir "" "$2" "$pmaj")"
        why="PHP $pmaj.$pmin ignores the directory, its configure takes the OpenSSL that pkg-config finds: $(ossl_text "$inc") ($inc)"
    fi
    awk -v o="$o" -v n="$n" '$0 == o { $0 = n } { print }' "$1" > "$1.new" && mv "$1.new" "$1"
    ossl_note="$o replaced with $n: $why${ossl_note:+; $ossl_note}"
}

# The curl option of the script ($1: options, one per line, changed in place; $2:
# environment lines): --with-curl becomes --with-curl=bundled when this source tree
# bundles curl (ext/curl/libcurl) and the build's OpenSSL is 3.0 or later, which
# curl 8.18.0 and later need; with OpenSSL 1.1.1 (FreeBSD 13.x base) the libcurl of
# the curl package (ftp/curl, /usr/local) stays; the base system has no curl. Sets curl_note, and curl_pkgs for missing packages of the bundled curl.
curl_note="" curl_pkgs=""
curl_opts() {
    # with /usr/local/phpdeps installed, its libcurl (deps_opts)
    [ -f "${PHPDEPS:-/usr/local/phpdeps}/VERSIONS" ] && [ -x "${PHPDEPS:-/usr/local/phpdeps}/bin/pkg-config" ] && return 0
    [ -f ext/curl/build-libcurl.sh ] && [ -f ext/curl/libcurl/include/curl/curlver.h ] || return 0
    co="$(grep -E -m 1 '^--with-curl(=|$)' "$1")" || return 0
    case "$co" in *bundled*) return 0 ;; esac
    cv="$(sed -n 's/^#define LIBCURL_VERSION "\(.*\)"$/\1/p' ext/curl/libcurl/include/curl/curlver.h)"
    pmaj="$(sed -n 's/^#define PHP_MAJOR_VERSION \([0-9]*\).*/\1/p' main/php_version.h 2>/dev/null)"
    inc="$(ossl_incdir "$(sed -n 's/^--with-openssl=//p' "$1" | head -n 1)" "$2" "$pmaj")"
    ot="$(ossl_text "$inc")"
    if ! grep -q 'OPENSSL_VERSION_MAJOR' "$inc/openssl/opensslv.h" 2>/dev/null; then
        curl_note="$co kept: libcurl of the curl package (ftp/curl, /usr/local/lib; the base system has no curl): the curl $cv of this tree needs OpenSSL 3.0 or later (curl 8.18.0 dropped 1.1.1), this build takes ${ot:-no OpenSSL headers} from $inc"
        return 0
    fi
    case "$co" in --with-curl=shared*) nco="--with-curl=shared,bundled" ;; *) nco="--with-curl=bundled" ;; esac
    awk -v o="$co" -v n="$nco" '$0 == o { $0 = n } { print }' "$1" > "$1.new" && mv "$1.new" "$1"
    curl_note="$co replaced with $nco: curl $cv of this tree (ext/curl/libcurl) is built into PHP, with $ot ($inc); for the curl package (ftp/curl, /usr/local) instead: sh config.installed.sh $co"
    if command -v pkg >/dev/null 2>&1; then
        for p in libnghttp2 brotli zstd libidn2 libpsl; do
            pkg info -e "$p" 2>/dev/null || curl_pkgs="$curl_pkgs $p"
        done
    fi
}

# --with-openssl-legacy-provider (the option of PHP 8.4, in this fork for every
# version) for a build against OpenSSL 3, when the installed PHP can do RC4 (it was
# built against OpenSSL 1.1, or loads the legacy provider), and always for PHP 5.6
# and 7.4, which use RC4 as the default cipher of openssl_seal(): OpenSSL 3 keeps
# RC4, Blowfish, DES, RC2, CAST5 and MD4 in its legacy provider. $1: options
# (changed in place), $2: environment lines, $3: the installed PHP binary.
# Sets legacy_note.
legacy_note=""
installed_rc4() {
    [ -x "${1:-}" ] || return 1
    for a in -n ""; do
        # shellcheck disable=SC2086
        r="$("$1" $a -r 'if (function_exists("openssl_get_cipher_methods")) echo in_array("rc4", array_map("strtolower", openssl_get_cipher_methods())) ? "yes" : "no";' 2>/dev/null)"
        if [ -n "$r" ]; then [ "$r" = yes ]; return; fi
    done
    return 1
}
legacy_opts() {
    grep -q 'openssl-legacy-provider' ext/openssl/config0.m4 2>/dev/null || return 0
    grep -q -e '^--with-openssl' "$1" || return 0
    grep -q -e 'openssl-legacy-provider' "$1" && return 0
    pmaj="$(sed -n 's/^#define PHP_MAJOR_VERSION \([0-9]*\).*/\1/p' main/php_version.h 2>/dev/null)"
    pmin="$(sed -n 's/^#define PHP_MINOR_VERSION \([0-9]*\).*/\1/p' main/php_version.h 2>/dev/null)"
    why=""
    case "$pmaj" in
        5 | 7) why="PHP $pmaj.$pmin uses RC4 as the default cipher of openssl_seal()" ;;
    esac
    if installed_rc4 "${3:-}"; then
        why="the installed build can do RC4 (openssl_get_cipher_methods())${why:+; $why}"
    fi
    [ -n "$why" ] || return 0
    inc="$(ossl_incdir "$(sed -n 's/^--with-openssl=//p' "$1" | head -n 1)" "$2" "$pmaj")"
    grep -q 'OPENSSL_VERSION_MAJOR' "$inc/openssl/opensslv.h" 2>/dev/null || return 0
    printf '%s\n' --with-openssl-legacy-provider >> "$1"
    legacy_note="--with-openssl-legacy-provider added: $why, and $(ossl_text "$inc") keeps RC4, Blowfish, DES, RC2, CAST5 and MD4 in its legacy provider; without them: sh config.installed.sh --without-openssl-legacy-provider"
}

# The options of a bundled PECL module that keep the features of its installed
# build, as "php --ri" shows them (serializers, compression, SASL, swoole's hooks),
# where the bundled version has an option for them (ext/<module>/config.m4): for
# the shared modules of a hand build, and for the phpXY-pecl-* packages (--pkg).
# $1: the PHP binary that loads the installed module, $2: the module. Prints the
# options; what is not carried over goes to $tmp/pecl_note.
knows() { grep -q -e "\[$2\]" -e "($2," "ext/$1/config.m4" 2>/dev/null; }
ri_row() { sed -n "s/^$2 => //p" "$tmp/ri_$1" | head -n 1; }
pecl_feature_opts() {
    "$1" --ri "$2" > "$tmp/ri_$2" 2>/dev/null
    case "$2" in
        redis | memcached | swoole | openswoole)
            [ -s "$tmp/ri_$2" ] ||
                echo "$2: \"$1 --ri $2\" shows nothing, so the features of the installed build (serializers, compression, SASL) are not carried over; compare by hand" >> "$tmp/pecl_note" ;;
    esac
    case "$2" in
        redis)
            o="--enable-redis"
            ser=", $(ri_row redis 'Available serializers'),"
            cmp=", $(ri_row redis 'Available compression'),"
            case "$ser" in *", igbinary,"*) knows redis redis-igbinary && o="$o --enable-redis-igbinary" ;; esac
            case "$ser" in *", msgpack,"*) echo "redis: the msgpack serializer needs the msgpack extension, which is not bundled" >> "$tmp/pecl_note" ;; esac
            case "$cmp" in *", lzf,"*) knows redis redis-lzf && o="$o --enable-redis-lzf --with-liblzf" ;; esac
            case "$cmp" in *", zstd,"*) knows redis redis-zstd && o="$o --enable-redis-zstd" ;; esac
            case "$cmp" in *", lz4,"*) knows redis redis-lz4 && o="$o --enable-redis-lz4 --with-liblz4" ;; esac
            ;;
        memcached)
            o="--enable-memcached --with-libmemcached-dir=/usr/local"
            [ "$(ri_row memcached 'SASL support')" = yes ] || o="$o --disable-memcached-sasl"
            [ "$(ri_row memcached 'igbinary support')" = yes ] && o="$o --enable-memcached-igbinary"
            [ "$(ri_row memcached 'json support')" = yes ] && o="$o --enable-memcached-json"
            [ "$(ri_row memcached 'zstd support')" = yes ] && knows memcached zstd && o="$o --with-zstd"
            # the MemcachedServer class (libmemcachedprotocol and libevent; the FreeBSD
            # port always builds it), which --ri does not list
            [ "$("$1" -r 'echo class_exists("MemcachedServer", false) ? "yes" : "no";' 2>/dev/null)" = yes ] &&
                knows memcached memcached-protocol && o="$o --enable-memcached-protocol"
            [ "$(ri_row memcached 'msgpack support')" = yes ] &&
                echo "memcached: the msgpack serializer needs the msgpack extension, which is not bundled" >> "$tmp/pecl_note"
            ;;
        swoole | openswoole)
            o="--enable-$2"
            for pair in curl-native:swoole-curl c-ares:cares zstd:zstd http2:http2 json:swoole-json \
                coroutine_pgsql:swoole-pgsql coroutine_postgresql:swoole-pgsql coroutine_sqlite:swoole-sqlite; do
                [ -n "$(ri_row "$2" "${pair%%:*}")" ] && knows "$2" "${pair#*:}" && o="$o --enable-${pair#*:}"
            done
            [ -n "$(ri_row "$2" postgresql)" ] && knows "$2" postgres && o="$o --with-postgres"
            for row in coroutine_odbc coroutine_oracle coroutine_firebird; do
                [ -n "$(ri_row "$2" "$row")" ] && echo "$2: $row was enabled; add its --with-swoole-... option by hand (./configure --help)" >> "$tmp/pecl_note"
            done
            ;;
        imagick | gmagick | mcrypt) o="--with-$2=/usr/local" ;;
        *) o="--enable-$2" ;;
    esac
    printf '%s\n' "$o"
}

# /usr/local/phpdeps (tools/build-deps.sh; the release phpdeps-fbsd<major>-latest):
# static, position independent libraries for PHP. When it is installed, the
# options of the libraries it has point there, pkg-config is its wrapper (the
# bundle first, static link lines) and LDFLAGS put it first and keep its symbols
# hidden, so that php, php-fpm and libphp.so need no library of /usr/local/lib.
# $1: options (changed in place), $2: environment lines (changed in place).
# Sets deps_note.
PHPDEPS="${PHPDEPS:-/usr/local/phpdeps}"
deps_note=""
deps_opts() {
    [ -f "$PHPDEPS/VERSIONS" ] && [ -x "$PHPDEPS/bin/pkg-config" ] || return 0
    pmaj="$(sed -n 's/^#define PHP_MAJOR_VERSION \([0-9]*\).*/\1/p' main/php_version.h 2>/dev/null)"
    awk -v d="$PHPDEPS" -v fam="${pmaj:-8}" '
        # the value of a --with option, with "shared," kept
        function to_deps(name, val,   sh) {
            sh = (val ~ /^shared(,|$)/) ? "shared," : ""
            return name "=" sh d
        }
        { name = $0; val = ""; if (index($0, "=")) { name = substr($0, 1, index($0, "=") - 1); val = substr($0, index($0, "=") + 1) } }
        name == "--with-openssl" && fam == 5 { print to_deps(name, val); next }
        name == "--with-curl" || name == "--with-iconv" || name == "--with-readline" || \
        name == "--with-external-pcre" || name == "--with-pcre-regex" || name == "--with-mcrypt" || \
        name == "--with-libmemcached-dir" || name == "--with-password-argon2" || name == "--with-gettext" || \
        name == "--with-libxml-dir" || name == "--with-jpeg-dir" || name == "--with-png-dir" || \
        name == "--with-freetype-dir" || name == "--with-webp-dir" || name == "--with-sodium" || \
        name == "--with-icu-dir" || name == "--with-onig" || name == "--with-libzip" {
            if (val == "no") { print; next }
            print to_deps(name, val); n++; next
        }
        { print }
    ' "$1" > "$1.new" && mv "$1.new" "$1"
    sasl=""
    if grep -qx -- --enable-memcached "$1" && ! grep -qx -- --disable-memcached-sasl "$1"; then
        printf '%s\n' --disable-memcached-sasl >> "$1"
        sasl="; memcached without SASL (cyrus-sasl is not in the bundle: --enable-memcached-sasl and its pkg libraries, if a server needs it)"
    fi
    # LDFLAGS: the bundle first, its symbols not exported (an Apache with other modules).
    if grep -q '^LDFLAGS=' "$2" 2>/dev/null; then
        sed -E "s#^LDFLAGS='?#LDFLAGS='-L$PHPDEPS/lib -Wl,--exclude-libs,ALL #; s#^(LDFLAGS='[^']*[^' ])\$#\1'#" "$2" > "$2.new" && mv "$2.new" "$2"
    else
        printf "LDFLAGS='-L%s/lib -Wl,--exclude-libs,ALL'\n" "$PHPDEPS" >> "$2"
    fi
    printf "PKG_CONFIG='%s/bin/pkg-config'\n" "$PHPDEPS" >> "$2"
    # what still links against pkg libraries: library options with a /usr/local value
    still="$(grep -E '^--with-[a-zA-Z0-9-]+=(shared,)?/usr/local($|/)' "$1" | grep -v -e "$PHPDEPS" |
        grep -v -E '^--with-(apxs2?|config-file-|mysql-sock|fpm-|layout)' | tr '\n' ' ' | sed 's/ *$//')"
    deps_note="the libraries come from $PHPDEPS ($(head -n 1 "$PHPDEPS/VERSIONS" | sed 's/, built.*//')): static, linked into PHP${sasl}${still:+; still from pkg: $still}; check after make install: ldd <prefix>/bin/php <prefix>/sbin/php-fpm | grep /usr/local/lib"
}

# --deps-rewrite <options> <env> (for tools/build-test.sh): the rewrite of
# deps_opts on an options file (one per line) and an environment file
# (NAME='value' lines), run from inside the PHP source tree; prints the note.
if [ "${1:-}" = "--deps-rewrite" ]; then
    [ $# -eq 3 ] || { echo "config-check: --deps-rewrite <options file> <env file>" >&2; exit 2; }
    [ -f "$PHPDEPS/VERSIONS" ] || { echo "config-check: no $PHPDEPS/VERSIONS" >&2; exit 2; }
    touch "$3"
    deps_opts "$2" "$3"
    echo "$deps_note"
    exit 0
fi

# --pkg: the ./configure options for a hand build that replaces the PHP installed
# as FreeBSD packages (lang/phpXY, its phpXY-* extension packages, mod_phpXY), in
# the layout of our hand builds, with CFLAGS from /etc/make.conf.
if [ "${1:-}" = "--pkg" ]; then
    [ $# -le 2 ] || { sed -n 's/^# \{0,1\}//; 7,10p' "$0" >&2; exit 2; }
    pkg="${PKG:-pkg}"
    lb="${LOCALBASE:-/usr/local}"
    tmp="$(mktemp -d)" || exit 2
    trap 'rm -rf "$tmp"' EXIT INT TERM

    want="${2:-}"
    case "$want" in
        "" | php[0-9][0-9]) ;;
        [0-9].[0-9]) want="php$(printf '%s' "$want" | tr -d .)" ;;
        [0-9][0-9]) want="php$want" ;;
        *) echo "config-check: --pkg takes a package name (php74), a version (7.4) or 74" >&2; exit 2 ;;
    esac
    cores="$("$pkg" query -g '%n' 'php[0-9][0-9]' 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
    if [ -z "$want" ]; then
        case "$cores" in
            "") echo "config-check: no PHP package (lang/phpXY) is installed" >&2; exit 2 ;;
            *" "*) echo "config-check: several PHP packages are installed ($cores); name one: sh config-check.sh --pkg php74" >&2; exit 2 ;;
        esac
        want="$cores"
    fi
    pkgver="$("$pkg" query '%v' "$want" 2>/dev/null)"
    [ -n "$pkgver" ] || { echo "config-check: $want is not installed (PHP packages: ${cores:-none})" >&2; exit 2; }
    short="${want#php}"
    minor="${short#?}"
    case "$short" in
        5*) fam=5 ;;
        7*) fam=7 ;;
        *) fam=8 ;;
    esac
    prefix="/usr/local/php$short"

    : > "$tmp/opts"; : > "$tmp/map"; : > "$tmp/skip"; : > "$tmp/notes"; : > "$tmp/pecl_note"
    add() { for o in "$@"; do grep -qxF -- "$o" "$tmp/opts" || printf '%s\n' "$o" >> "$tmp/opts"; done; }
    note() { printf '%s\n' "$*" >> "$tmp/notes"; }
    has() { [ -f "$lb/include/$1" ]; }
    "$pkg" query '%Ok %Ov' "$want" > "$tmp/core" 2>/dev/null
    opt() { grep -qx "$1 $2" "$tmp/core"; }
    "$pkg" query '%dn' "$want" > "$tmp/deps" 2>/dev/null
    modphp="$("$pkg" query -g '%n' "mod_php$short" 2>/dev/null)"
    intl=""

    # Configure options of one extension package, in the style of our hand builds
    # (the FreeBSD port's Makefile.ext passes the same, mostly with LOCALBASE paths).
    # Exit 1 with the reason on stdout for a package that has no option.
    ext_flags() {
        case "$1" in
            bcmath|calendar|ctype|dba|dom|exif|fileinfo|filter|ftp|mbstring|pcntl|pdo|phar|posix|\
session|shmop|simplexml|soap|sockets|sysvmsg|sysvsem|sysvshm|tokenizer|xml|xmlreader|xmlwriter)
                echo "--enable-$1" ;;
            json) [ "$fam" = 8 ] || echo "--enable-json" ;;
            opcache) if [ "$fam" = 8 ]; then echo "--enable-opcache --enable-opcache-jit"; else echo "--enable-opcache"; fi ;;
            intl) if [ "$fam" = 5 ]; then echo "--enable-intl --with-icu-dir=/usr/local"; else echo "--enable-intl"; fi ;;
            bz2) echo "--with-bz2" ;;
            curl) if [ "$fam" = 5 ]; then echo "--with-curl"; else echo "--with-curl=/usr/local"; fi ;;
            enchant) echo "--with-enchant=/usr/local" ;;
            ffi) echo "--with-ffi" ;;
            gd)
                if [ "$fam" = 5 ]; then
                    f="--with-gd"
                    has jpeglib.h && f="$f --with-jpeg-dir=/usr/local"
                    has png.h && f="$f --with-png-dir=/usr/local"
                    has freetype2/ft2build.h && f="$f --with-freetype-dir=/usr/local"
                    echo "$f"
                else
                    has gd.h || note "--with-external-gd needs the libgd package ($lb/include/gd.h is missing)."
                    echo "--enable-gd --with-external-gd"
                fi ;;
            gettext) if [ "$fam" = 5 ]; then echo "--with-gettext"; else echo "--with-gettext=/usr/local"; fi ;;
            gmp) echo "--with-gmp=/usr/local" ;;
            iconv) echo "--with-iconv=/usr/local" ;;
            imap) if [ "$fam" = 8 ] && [ "$minor" -ge 4 ]; then echo "removed from PHP in 8.4 (PECL imap)"; return 1; fi
                  echo "--with-imap=/usr/local --with-imap-ssl=/usr" ;;
            ldap) echo "--with-ldap=/usr/local" ;;
            mcrypt) if [ "$fam" = 5 ]; then echo "--with-mcrypt=/usr/local"; else echo "removed from PHP in 7.2 (PECL mcrypt, bundled: --with-mcrypt=/usr/local)"; return 1; fi ;;
            mysql) if [ "$fam" = 5 ]; then echo "--with-mysql --with-mysql-sock=/tmp/mysql.sock"; else echo "removed from PHP in 7.0 (use mysqli or pdo_mysql)"; return 1; fi ;;
            mysqli) if [ "$fam" = 5 ]; then echo "--with-mysqli --with-mysql-sock=/tmp/mysql.sock"; else echo "--with-mysqli=mysqlnd --with-mysql-sock=/tmp/mysql.sock"; fi ;;
            odbc) echo "--with-unixODBC=/usr/local" ;;
            openssl) case "$fam" in 5) echo "--with-openssl=/usr" ;; 7) echo "--with-openssl" ;; *) echo "--with-openssl=/usr" ;; esac ;;
            pdo_dblib) echo "--with-pdo-dblib=/usr/local" ;;
            pdo_firebird) echo "--with-pdo-firebird=/usr/local" ;;
            pdo_mysql) if [ "$fam" = 5 ]; then echo "--with-pdo-mysql --with-mysql-sock=/tmp/mysql.sock"; else echo "--with-pdo-mysql=mysqlnd --with-mysql-sock=/tmp/mysql.sock"; fi ;;
            pdo_odbc) echo "--with-pdo-odbc=unixODBC,/usr/local" ;;
            pdo_pgsql) echo "--with-pdo-pgsql=/usr/local" ;;
            pdo_sqlite) if [ "$fam" = 5 ]; then echo "--with-pdo-sqlite=/usr/local"; else echo "--with-pdo-sqlite"; fi ;;
            pgsql) echo "--with-pgsql=/usr/local" ;;
            pspell) if [ "$fam" = 8 ] && [ "$minor" -ge 4 ]; then echo "removed from PHP in 8.4 (PECL pspell)"; return 1; fi
                    echo "--with-pspell=/usr/local" ;;
            readline) if has readline/readline.h; then echo "--with-readline=/usr/local"; else echo "--with-libedit"; fi ;;
            snmp) echo "--with-snmp=/usr/local" ;;
            sodium) echo "--with-sodium=/usr/local" ;;
            sqlite3) if [ "$fam" = 5 ]; then echo "--with-sqlite3=/usr/local"; else echo "--with-sqlite3"; fi ;;
            tidy) echo "--with-tidy=/usr/local" ;;
            wddx) if [ "$fam" = 5 ]; then echo "--enable-wddx"; else echo "removed from PHP in 7.4"; return 1; fi ;;
            xmlrpc) if [ "$fam" = 8 ]; then echo "removed from PHP in 8.0 (PECL xmlrpc)"; return 1; fi; echo "--with-xmlrpc" ;;
            xsl) if [ "$fam" = 5 ]; then echo "--with-xsl=/usr/local"; else echo "--with-xsl"; fi ;;
            zip) if [ "$fam" = 5 ]; then echo "--enable-zip"; else echo "--with-zip"; fi ;;
            zlib) if [ "$fam" = 5 ]; then echo "--with-zlib=/usr"; else echo "--with-zlib"; fi ;;
            # with the features the package was built with (php --ri of the package PHP)
            pecl-redis | pecl-memcached | pecl-memcache | pecl-imagick | pecl-igbinary | pecl-swoole | \
pecl-openswoole | pecl-excimer | pecl-gmagick | pecl-mcrypt)
                pecl_feature_opts "$lb/bin/php" "${1#pecl-}" ;;
            pecl-*) echo "PECL extension, not part of ./configure: build it later with $prefix/bin/phpize"; return 1 ;;
            *) echo "not an extension of the PHP sources (a tool, or one this script does not know)"; return 1 ;;
        esac
    }

    # The core package: layout of our hand builds, then its port options.
    [ -n "$modphp" ] && add --with-apxs2=/usr/local/sbin/apxs
    if [ "$fam" = 5 ]; then
        add --prefix="$prefix" --disable-all --with-layout=GNU --with-zend-vm=CALL --enable-libxml \
            --with-libxml-dir=/usr/local --with-regex=php --enable-mysqlnd
    else
        add --with-layout=GNU --localstatedir=/var --disable-all --with-libxml --program-prefix= \
            --prefix="$prefix" --mandir="$prefix/man" --infodir="$prefix/info/"
    fi
    opt CLI off && add --disable-cli
    opt CGI off && add --disable-cgi
    opt FPM on && add --enable-fpm --with-fpm-user=www --with-fpm-group=www
    # One build makes one SAPI module (./configure: "You can build only one SAPI
    # module"). The ports build the embed library (EMBED of phpXY) and the Apache
    # module (mod_phpXY) separately; with mod_phpXY installed the Apache module stays.
    if opt EMBED on; then
        if [ -n "$modphp" ]; then
            emb=libphp.so
            [ "$fam" = 8 ] || emb="libphp$fam.so"
            users="$("$pkg" shlib -qR "$emb" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
            if [ -n "$users" ]; then
                users="$emb is used by $users; for them, a second build makes the embed library: sh config.installed.sh --enable-embed --without-apxs2"
            else
                users="no package uses $emb (pkg shlib -R $emb)"
            fi
            note "embed: EMBED (the embed library $emb) is on in $want, and $modphp is installed. One PHP build makes only one SAPI module, the ports build the two separately: the Apache module (--with-apxs2) is kept, --enable-embed left out; $users."
        else
            add --enable-embed
        fi
    fi
    opt PHPDBG on && add --enable-phpdbg
    opt IPV6 off && add --disable-ipv6
    if opt ZTS on; then
        if [ "$fam" = 8 ]; then add --enable-zts; else add --enable-maintainer-zts; fi
    fi
    opt MYSQLND on && add --enable-mysqlnd
    libs=""
    opt LINKTHR on && libs="-lpthread"
    opt DEBUG on && note "DEBUG is on in the package: not carried over (add --enable-debug for a debug build)."
    opt DTRACE on && note "DTRACE is on in the package: not carried over (add --enable-dtrace to keep the DTrace probes)."
    opt MAILHEAD on && note "MAILHEAD (the mail() header patch of the php56 port) is not in this fork."
    if [ "$fam" = 5 ]; then
        if has pcre.h; then add --with-pcre-regex=/usr/local
        else note "No $lb/include/pcre.h (package pcre): the old bundled PCRE 8.38 is used."; fi
    elif ! opt PCRE off; then
        if has pcre2.h; then add --with-external-pcre=/usr/local
        else note "No $lb/include/pcre2.h (package pcre2): the bundled PCRE2 is used."; fi
    fi
    if [ "$fam" = 8 ]; then
        add --with-openssl=/usr
    fi
    if [ "$fam" != 5 ]; then
        if grep -qx libargon2 "$tmp/deps"; then add --with-password-argon2=/usr/local
        elif [ "$fam" = 8 ] && [ "$minor" -ge 4 ]; then add --with-openssl-argon2; fi
    fi

    # The extension packages (igbinary first: redis and memcached use it when present).
    # pkg matches the glob against name-version too, so php74-* brings php74 itself.
    "$pkg" query -g '%n' "php$short-*" 2>/dev/null | grep -v -x -F -e "$want" | sort > "$tmp/ext_pkgs"
    n_ext=0
    while IFS= read -r p; do
        e="${p#php"$short"-}"
        [ "$e" = extensions ] && continue
        if f="$(ext_flags "$e")"; then
            [ "$e" = intl ] && intl=1
            # shellcheck disable=SC2086
            [ -n "$f" ] && add $f
            printf '  %-24s %s\n' "$p" "${f:-(built into PHP $fam, no option)}" >> "$tmp/map"
            n_ext=$((n_ext + 1))
        else
            printf '  %-24s %s\n' "$p" "$f" >> "$tmp/skip"
        fi
    done < "$tmp/ext_pkgs"
    sort -u "$tmp/pecl_note" | while IFS= read -r l; do note "$l"; done
    if grep -qx "php$short-pecl-igbinary" "$tmp/ext_pkgs"; then
        grep -qx -- "--enable-redis" "$tmp/opts" && add --enable-redis-igbinary
        grep -qx -- "--enable-memcached" "$tmp/opts" && add --enable-memcached-igbinary
    fi

    # CFLAGS: those of /etc/make.conf plus -march=$CPUTYPE, as for the ports.
    mc_cflags="$(mc_get CFLAGS)"
    cputype="$(mc_get CPUTYPE)"
    cflags="$(mc_cflags)"
    cxxflags="$cflags"
    [ -n "$intl" ] && [ "$fam" != 5 ] && cxxflags="-std=c++17 $cflags"

    curl_opts "$tmp/opts" /dev/null
    [ -n "$curl_note" ] && note "curl: $curl_note"
    legacy_opts "$tmp/opts" /dev/null "$lb/bin/php"
    [ -n "$legacy_note" ] && note "openssl: $legacy_note"
    : > "$tmp/pkg_env"
    deps_opts "$tmp/opts" "$tmp/pkg_env"
    [ -n "$deps_note" ] && note "phpdeps: $deps_note"

    out_dir="$(cd "$(dirname "$out")" 2>/dev/null && pwd)" || { echo "config-check: no directory for $out" >&2; exit 2; }
    out="$out_dir/$(basename "$out")"
    {
        echo "#!/bin/sh"
        echo "# Written by config-check.sh --pkg on $(date '+%d.%m.%Y %H:%M'): a hand build that replaces"
        echo "# the packages $want $pkgver${modphp:+, $modphp} and $n_ext extension packages; CFLAGS from $mk_conf."
        echo "# Run from inside the new PHP source tree: sh $out"
        echo
        printf "CFLAGS='%s' \\\\\n" "$cflags"
        printf "CXXFLAGS='%s' \\\\\n" "$cxxflags"
        [ -n "$libs" ] && printf "LIBS='%s' \\\\\n" "$libs"
        sed 's/$/ \\/' "$tmp/pkg_env"
        echo "'./configure' \\"
        sed "s/'/'\\\\''/g; s/^/'/; s/\$/' \\\\/" "$tmp/opts"
        echo '"$@"'
    } > "$out" || { echo "config-check: cannot write $out" >&2; exit 2; }
    chmod +x "$out" 2>/dev/null || true

    # Report.
    printf 'packages:   %s %s%s, %s extension packages\n' "$want" "$pkgver" "${modphp:+, $modphp}" "$n_ext"
    printf 'port opts:  %s\n' "$(tr '\n' ',' < "$tmp/core" | sed 's/,$//; s/,/, /g')"
    printf 'make.conf:  CPUTYPE=%s, CFLAGS=%s (%s)\n' "${cputype:-unset}" "${mc_cflags:-unset}" "$mk_conf"
    m="$(mc_march)"
    lacks="$(cpu_lacks "$m")"
    if [ -n "$lacks" ]; then
        echo
        echo "WARNING: -march=$m needs $lacks, which this CPU does not have:"
        echo "         PHP built with it stops with \"Illegal instruction\" here. Check CPUTYPE in $mk_conf."
    fi
    echo
    echo "extension packages and their options:"
    cat "$tmp/map"
    if [ -s "$tmp/skip" ]; then
        echo
        echo "not carried over:"
        cat "$tmp/skip"
    fi
    echo
    echo "notes:"
    sed 's/^/  - /' "$tmp/notes"
    echo "  - php.ini: the packages read /usr/local/etc/php.ini and /usr/local/etc/php/*.ini; the new build"
    echo "    reads $prefix/etc/php.ini. The extensions are compiled in, the ext-*.ini files are not needed."
    if [ -n "$modphp" ]; then
        echo "  - make install puts the Apache module where $modphp has it: run pkg delete $modphp first,"
        echo "    or the next pkg upgrade writes the package's module over it."
    fi
    opt FPM on && echo "  - php-fpm goes to $prefix/sbin/php-fpm; the package's rc.d script starts /usr/local/sbin/php-fpm."
    set -- "$want"
    [ -n "$modphp" ] && set -- "$@" "$modphp"
    while IFS= read -r p; do set -- "$@" "$p"; done < "$tmp/ext_pkgs"
    {
        "$pkg" query '%dn' "$@" 2>/dev/null | grep -v -e '^php' -e '^mod_php'
        # the bundled curl is linked in, the libraries it links against come from packages
        if grep -q -e '^--with-curl=.*bundled' "$tmp/opts"; then
            for p in libnghttp2 brotli zstd libidn2 libpsl; do
                "$pkg" info -e "$p" 2>/dev/null && echo "$p"
            done
        fi
    } | sort -u > "$tmp/libs"
    if [ -s "$tmp/libs" ]; then
        echo "  - Before deleting the PHP packages, keep the libraries the new build links against, so that"
        echo "    pkg autoremove does not remove them:"
        echo
        echo "pkg set -y -A 0 $(tr '\n' ' ' < "$tmp/libs" | sed 's/ *$//')"
    fi
    if [ -n "$curl_pkgs" ]; then
        echo "  - The bundled curl needs packages that are not installed:"
        echo
        echo "pkg install -y$curl_pkgs"
    fi
    echo
    echo "written: $out"
    echo "next, from inside the new source tree: sh $out"
    exit 0
fi

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    sed -n 's/^# \{0,1\}//; 7,10p' "$0" >&2
    exit 2
fi
target="$1"
nice="${2:-}"

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
# Options that cannot be read from the installed build (a binary that does not run)
# come from config.nice (below).
broken=""
if [ -n "$line" ]; then
    to_lines "$line" "$how" > "$tmp/installed_order"
    LC_ALL=C sort -u "$tmp/installed_order" > "$tmp/installed"
    version="$("$php" -n -v 2>/dev/null | head -1)"
    ver="$(printf '%s\n' "$version" | awk '{print $2}')"
else
    "$php" -n -v > "$tmp/broken_out" 2>&1
    brc=$?
    if [ "$brc" = 0 ]; then
        broken="no Configure Command in $php -n -i and no php-config"
        version="$(head -n 1 "$tmp/broken_out")"
        ver="$(printf '%s\n' "$version" | awk '{print $2}')"
    else
        broken="$php does not run: -n -v exits with $brc"
        [ "$brc" -gt 128 ] && broken="$broken (signal $((brc - 128)))"
        err="$(grep -v -e '^[[:space:]]*$' "$tmp/broken_out" | head -n 2 | tr '\n' ' ' | sed 's/ *$//')"
        [ -n "$err" ] && broken="$broken: $err"
        version=""
        # the version of this source tree, to find its config.nice (a rebuild of the same version)
        ver="$(sed -n 's/^#define PHP_VERSION "\([^"]*\)".*/\1/p' main/php_version.h 2>/dev/null | head -n 1)"
    fi
fi

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
        to_lines "$(cat "$tmp/nice_args")" "$nice" > "$tmp/nice_order"
        LC_ALL=C sort -u "$tmp/nice_order" > "$tmp/nice"
    fi
    [ -s "$tmp/nice" ] || { echo "config-check: no configure options found in $nice" >&2; exit 2; }
fi

if [ -n "$broken" ]; then
    if [ -z "$nice" ]; then
        echo "config-check: no configure options from $php ($broken)" >&2
        echo "config-check: give the config.nice of that build as the second argument, its options are used then" >&2
        exit 2
    fi
    echo "config-check: warning: the options of the installed build cannot be read ($broken); those of $nice are used as they are" >&2
    cp "$tmp/nice_order" "$tmp/installed_order"
    cp "$tmp/nice" "$tmp/installed"
    how="$nice (the installed build cannot be read)"
fi

# Without a config.nice the environment comes from /etc/make.conf, as for the
# ports: its CFLAGS with -march=$CPUTYPE, and -lpthread (LINKTHR of lang/phpXY).
if [ -z "$nice" ]; then
    cf="$(mc_cflags)"
    cxf="$cf"
    case "$ver" in
        5.*) ;;
        *) grep -q -e '^--enable-intl' "$tmp/installed" && cxf="-std=c++17 $cf" ;;
    esac
    printf "CFLAGS='%s'\nCXXFLAGS='%s'\nLIBS='-lpthread'\n" "$cf" "$cxf" > "$tmp/env"
fi

# -march: /etc/make.conf of this server decides (CPUTYPE, or a -march= in its
# CFLAGS), so that a config.nice from a server with another CPU does not bring
# its -march along. The CFLAGS options that PHP 5.6 records go the same way.
march_note=""
mm="$(mc_march)"
old_march="$(march_in "$tmp/env" "$tmp/installed_order")"
if [ -n "$mm" ] && [ -n "$old_march" ] && [ "$old_march" != "$mm" ]; then
    for f in "$tmp/env" "$tmp/installed_order"; do
        sed -E "/^'?C(XX)?FLAGS=/ s/-march=[^ '\"]+/-march=$mm/g" "$f" > "$f.new" && mv "$f.new" "$f"
    done
    march_note="-march=$old_march of ${nice:-?} replaced with -march=$mm (CPUTYPE of $mk_conf)"
fi
cur_march="$(march_in "$tmp/env" "$tmp/installed_order" | awk '{ print $NF }')"
lacks="$(cpu_lacks "$cur_march")"
ossl_opts "$tmp/installed_order" "$tmp/env"
curl_opts "$tmp/installed_order" "$tmp/env"
legacy_opts "$tmp/installed_order" "$tmp/env" "$php"
deps_opts "$tmp/installed_order" "$tmp/env"

printf 'installed:   %s\n             %s\n             %s options, from %s\n' \
    "$php" "${version:-?}" "$(wc -l < "$tmp/installed" | tr -d ' ')" "$how"
if [ -n "$broken" ]; then
    printf '             NOT READ: %s\n' "$broken"
fi
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
    if [ -n "$nice" ]; then
        echo "environment in config.nice (not recorded by the installed build, not compared):"
    else
        echo "environment from $mk_conf (no config.nice):"
    fi
    sed 's/^/  /' "$tmp/env"
fi
if [ -n "$march_note" ]; then
    echo
    echo "march: $march_note"
fi
if [ -n "$lacks" ]; then
    echo
    echo "WARNING: -march=$cur_march needs $lacks, which this CPU does not have:"
    echo "         PHP built with it stops with \"Illegal instruction\" here. Check CPUTYPE in $mk_conf."
fi
if [ -n "$ossl_note" ]; then
    echo
    echo "openssl: $ossl_note"
fi
if [ -n "$legacy_note" ]; then
    echo
    echo "openssl: $legacy_note"
fi
if [ -n "$deps_note" ]; then
    echo
    echo "phpdeps: $deps_note"
fi
if [ -n "$curl_note" ]; then
    echo
    echo "curl: $curl_note"
    if [ -n "$curl_pkgs" ]; then
        echo "      packages it needs that are not installed:"
        echo
        echo "pkg install -y$curl_pkgs"
    fi
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
    if [ -n "$nice" ] && [ -s "$tmp/env" ]; then
        echo "# The environment lines come from $nice (the installed build does not record them)."
    elif [ -s "$tmp/env" ]; then
        echo "# The environment lines come from $mk_conf (no config.nice)."
    fi
    [ -n "$march_note" ] && echo "# $march_note."
    [ -n "$curl_note" ] && echo "# curl: $curl_note."
    [ -n "$ossl_note" ] && echo "# openssl: $ossl_note."
    [ -n "$legacy_note" ] && echo "# openssl: $legacy_note."
    [ -n "$deps_note" ] && echo "# phpdeps: $deps_note."
    echo "# Run from inside the new PHP source tree: sh $out"
    echo
    sed 's/$/ \\/' "$tmp/env"
    echo "'./configure' \\"
    sed "s/'/'\\\\''/g; s/^/'/; s/\$/' \\\\/" "$tmp/installed_order"
    echo '"$@"'
} > "$out" || { echo "config-check: cannot write $out" >&2; exit 2; }
chmod +x "$out" 2>/dev/null || true

# Shared PECL modules of the installed PHP that this source tree bundles in ext/:
# they are not built in on their own; the report ends with the command that builds
# them in (the script plus their options), ready to copy. The features a module was
# built with ("php --ri": serializers, compression, swoole's hooks) are carried over
# where the bundled version has an option for them (its config.m4).
# A binary that does not run has no "php -m" and no "php --ini": its php.ini files
# are looked for (ini_candidates) and its shared modules are those their extension=
# lines load.
# The php.ini files of the installed build: --with-config-file-path (a file, or
# <dir>/php.ini and <dir>/php-*.ini; <prefix>/lib/php.ini without it) and
# --with-config-file-scan-dir (<dir>/*.ini) of its options, the layout of the hand
# builds (<prefix>/etc/php*.ini, /usr/local/etc/phpXY.ini, /usr/local/etc/phpXY/*.ini)
# and the PHPIniDir lines of Apache that name phpXY or the prefix. Existing files
# only, each once (symbolic links resolved).
ini_candidates() {
    pfx="$(sed -n 's/^--prefix=//p' "$tmp/installed" | head -n 1)"
    [ -n "$pfx" ] || pfx="$(cd "$(dirname "$php")/.." 2>/dev/null && pwd)"
    vt="$(sed -n 's/^#define PHP_MAJOR_VERSION \([0-9]*\).*/\1/p' main/php_version.h 2>/dev/null)"
    [ -n "$vt" ] && vt="$vt$(sed -n 's/^#define PHP_MINOR_VERSION \([0-9]*\).*/\1/p' main/php_version.h 2>/dev/null)"
    [ -n "$vt" ] || vt="$(basename "$pfx" | sed -n 's/^php\([0-9][0-9]*\)$/\1/p')"
    cfp="$(sed -n 's/^--with-config-file-path=//p' "$tmp/installed" | head -n 1)"
    csd="$(sed -n 's/^--with-config-file-scan-dir=//p' "$tmp/installed" | head -n 1)"
    {
        if [ -z "$cfp" ]; then
            echo "$pfx/lib/php.ini"
        elif [ -d "$cfp" ]; then
            ls "$cfp"/php.ini "$cfp"/php-*.ini 2>/dev/null
        else
            echo "$cfp"
        fi
        [ -n "$csd" ] && ls "$csd"/*.ini 2>/dev/null
        ls "$pfx"/etc/php*.ini 2>/dev/null
        if [ -n "$vt" ]; then
            echo "/usr/local/etc/php$vt.ini"
            ls "/usr/local/etc/php$vt"/*.ini 2>/dev/null
        fi
        for d in /usr/local/etc/apache24 /usr/local/etc/apache22; do
            [ -d "$d" ] || continue
            grep -rhs -E '^[[:space:]]*PHPIniDir[[:space:]]' "$d" | awk '{ v = $2; gsub(/"/, "", v); print v }' |
                while IFS= read -r v; do
                    case "$v" in
                        "$pfx" | "$pfx"/*) ;;
                        *) [ -n "$vt" ] || continue; case "$v" in *"php$vt"*) ;; *) continue ;; esac ;;
                    esac
                    if [ -d "$v" ]; then ls "$v"/php.ini "$v"/php-apache2handler.ini 2>/dev/null; else echo "$v"; fi
                done
        done
    } | while IFS= read -r f; do
        [ -f "$f" ] && [ -r "$f" ] || continue
        printf '%s %s\n' "$(realpath "$f" 2>/dev/null || echo "$f")" "$f"
    done | awk '!seen[$1]++ { sub(/^[^ ]* /, ""); print }'
}
: > "$tmp/ini_files"
if [ -n "$broken" ]; then
    ini_candidates > "$tmp/ini_files"
    while IFS= read -r f; do
        sed -n -E "s/^[[:space:]]*extension[[:space:]]*=[[:space:]]*[\"']?([^\"';[:space:]]*)[\"']?.*/\\1/p" "$f"
    done < "$tmp/ini_files" | sed 's#.*/##; s/\.so$//' | tr 'A-Z' 'a-z' | sort -u > "$tmp/modules"
else
    "$php" -m 2>/dev/null | tr 'A-Z' 'a-z' > "$tmp/modules"
fi
: > "$tmp/pecl_hint"
: > "$tmp/pecl_note"
if [ -n "$broken" ]; then
    if [ -s "$tmp/ini_files" ]; then
        echo "the installed build cannot be read: its shared modules are those of the extension= lines of $(tr '\n' ' ' < "$tmp/ini_files" | sed 's/ *$//'); check that this is the php.ini it loads" >> "$tmp/pecl_note"
    else
        echo "the installed build cannot be read and no php.ini of it was found (--with-config-file-path, <prefix>/etc/php*.ini, /usr/local/etc/phpXY.ini, Apache PHPIniDir): check the extension= lines of its php.ini by hand" >> "$tmp/pecl_note"
    fi
fi
: > "$tmp/pecl_opts"
: > "$tmp/pecl_names"
: > "$tmp/ini_lines"
for m in igbinary redis memcached memcache imagick gmagick swoole openswoole excimer mcrypt; do
    grep -qx "$m" "$tmp/modules" || continue
    grep -q -e "--enable-$m\$" -e "--enable-$m=" -e "--with-$m" "$tmp/installed" && continue
    if [ ! -d ext/standard ]; then
        grep -q 'source tree' "$tmp/pecl_note" ||
            echo "run config-check.sh from inside the new PHP source tree to get the options for $m and the other shared PECL modules" >> "$tmp/pecl_note"
        continue
    fi
    if [ ! -f "ext/$m/config.m4" ] && [ ! -f "ext/$m/config9.m4" ]; then
        echo "$m is not bundled for PHP ${ver:-?}: keep its extension= line" >> "$tmp/pecl_note"
        continue
    fi
    o="$(pecl_feature_opts "$php" "$m")"
    printf '  %-10s %s\n' "$m" "$o" >> "$tmp/pecl_hint"
    # shellcheck disable=SC2086
    printf '%s\n' $o >> "$tmp/pecl_opts"
    echo "$m" >> "$tmp/pecl_names"
done

# What they need from PHP itself, when the installed build has not got it.
need() { grep -qx -e "$1" "$tmp/pecl_opts" "$tmp/installed" || printf '%s\n' "$1" >> "$tmp/pecl_opts"; }
# Whether the installed build has module $1 (json, hash, session: on by default).
# Without "php -m" (a binary that does not run) its options tell.
has_mod() {
    grep -qx "$1" "$tmp/modules" && return 0
    [ -n "$broken" ] || return 1
    grep -qx -e "--enable-$1" -e "--enable-$1=.*" "$tmp/installed" && return 0
    ! grep -qx -e "--disable-$1" -e --disable-all "$tmp/installed"
}
fam="${ver%%.*}"
if grep -qx redis "$tmp/pecl_names"; then
    case "$fam" in 5 | 7) has_mod json || need --enable-json ;; esac
    if [ "$fam" = 5 ]; then has_mod hash || need --enable-hash; fi
fi
if grep -qx -e redis -e memcached "$tmp/pecl_names"; then
    has_mod session || need --enable-session
fi
pecl_line="$(awk '!seen[$0]++' "$tmp/pecl_opts" | tr '\n' ' ' | sed 's/ *$//')"

# The extension= lines that load them now (php --ini: php.ini and the scanned
# directory), to be removed once they are built in.
if [ -s "$tmp/pecl_names" ]; then
    if [ -z "$broken" ]; then
        "$php" --ini 2>/dev/null | awk '
            /^Loaded Configuration File:/ { sub(/^Loaded Configuration File:[ \t]*/, ""); print; next }
            /^Additional \.ini files parsed:/ { sub(/^Additional \.ini files parsed:[ \t]*/, ""); add = 1 }
            add { n = split($0, a, ","); for (i = 1; i <= n; i++) { f = a[i]; gsub(/^[ \t]+|[ \t]+$/, "", f); if (f != "") print f } }
        ' | grep -v '^(none)$' > "$tmp/ini_files"
    fi
    names="$(tr '\n' '|' < "$tmp/pecl_names" | sed 's/|$//')"
    while IFS= read -r f; do
        [ -r "$f" ] || continue
        grep -n -E "^[[:space:]]*extension[[:space:]]*=[[:space:]]*[\"']?([^\"';]*/)?($names)(\\.so)?[\"']?[[:space:]]*(;.*)?\$" "$f" |
            sed "s#^#  $f:#"
    done < "$tmp/ini_files" > "$tmp/ini_lines"
fi

if [ -s "$tmp/pecl_hint" ] || [ -s "$tmp/pecl_note" ]; then
    echo
    echo "shared PECL modules (extension=... in php.ini):"
    if [ -s "$tmp/pecl_hint" ]; then
        echo "  bundled in this tree, built in only with their options (the command is at the end):"
        sed 's/^/  /' "$tmp/pecl_hint"
    fi
    if [ -s "$tmp/ini_lines" ]; then
        echo "  after make install, remove the lines that load them, or PHP warns that they are loaded twice:"
        sed 's/^/  /' "$tmp/ini_lines"
    fi
    [ -s "$tmp/pecl_note" ] && sed 's/^/  note: /' "$tmp/pecl_note"
fi

echo
if [ -n "$broken" ]; then
    echo "RESULT: the installed build cannot be read, nothing compared; written from $nice."
    rc=1
elif [ -z "$nice" ]; then
    echo "RESULT: nothing to compare with; written from the installed build, with CFLAGS and"
    echo "        LIBS from $mk_conf. To carry over the environment of the old build instead,"
    echo "        give its config.nice as the second argument."
    rc=1
elif [ ! -s "$tmp/only_installed" ] && [ ! -s "$tmp/only_nice" ]; then
    echo "RESULT: same options; config.nice matches the installed build."
    rc=0
else
    echo "RESULT: different; the installed build wins."
    rc=1
fi
echo "written: $out"
if [ -n "$pecl_line" ]; then
    echo "next, from inside the new source tree, with the shared PECL modules built in:"
    echo
    echo "sh $out $pecl_line"
    echo
    echo "or without them: sh $out"
else
    echo "next, from inside the new source tree: sh $out"
fi
exit "$rc"
