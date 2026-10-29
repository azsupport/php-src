#!/bin/sh
# build-test.sh - build the release tarballs on FreeBSD with the ./configure
# options our servers use, and check the result. The GitHub workflow
# .github/workflows/build-test.yml runs it in a FreeBSD VM; it works the same on
# a FreeBSD server.
#
# Usage (from the top of a php-src checkout of master):
#   sh tools/build-test.sh --deps 5.6 7.4        install the packages the presets need
#   sh tools/build-test.sh --phpdeps <dir>       extract the phpdeps tarball of this CPU's level
#   sh tools/build-test.sh [--tests] 5.6 7.4     build dist/php-<target>-fbsd-latest.tar.xz
#
# Every target is unpacked into build-test/<target>, configured with its preset
# (below), built with make -j<cpus>, then checked: php -v, php -m, php-fpm -v,
# tools/build-test-smoke.php and, with --tests, a part of the PHP test suite.
# Results go to build-test-results/<target>/: summary.txt, errors.txt (first
# compiler errors), configure-tail.txt, smoke.txt, tests.txt (failed tests).
#
# Exit status: 0 every target built, 1 a target failed to configure or build.

set -u

top="$(pwd)"
res="$top/build-test-results"
work="$top/build-test"
dist="$top/dist"

deps() {
    # libmemcached, ImageMagick7-nox11, GraphicsMagick-nox11, libmcrypt: bundled PECL
    # memcached, imagick, gmagick, mcrypt (both magick packages nox11: the x11 flavour of
    # GraphicsMagick needs libwmf, which conflicts with the libwmf-nox11 of
    # ImageMagick7-nox11, and pkg -y then drops GraphicsMagick from the request);
    # memcached and redis: servers for the smoke checks of the PECL extensions;
    # no curl and none of the libraries of curl: the bundled curl brings them
    # (--with-curl=bundled, ext/curl/deps)
    pkgs="pkgconf libmemcached ImageMagick7-nox11 GraphicsMagick-nox11 libmcrypt memcached redis"
    if [ "${PHPDEPS_BUNDLE:-0}" = 1 ]; then
        # PHP against /usr/local/phpdeps: none of the libraries it has, so that
        # configure cannot take one of pkg by mistake; MAGICK=none leaves out the
        # magick packages too.
        pkgs="pkgconf memcached redis apache24 perl5"
        case "${MAGICK:-imagick}" in
            imagick) pkgs="$pkgs ImageMagick7-nox11" ;;
            gmagick) pkgs="$pkgs GraphicsMagick-nox11" ;;
        esac
        set --
    fi
    for t in "$@"; do
        case "$t" in
            5.6) pkgs="$pkgs libxml2 jpeg-turbo png freetype2 gettext-runtime libiconv libmcrypt pcre apache24 perl5" ;;
            7.4) pkgs="$pkgs libxml2 libargon2 readline libiconv libzip libgd webp pcre2 oniguruma" ;;
            8.*) pkgs="$pkgs libxml2 readline libiconv libzip libgd webp pcre2 oniguruma icu apache24 perl5" ;;
        esac
    done
    # shellcheck disable=SC2086
    env ASSUME_ALWAYS_YES=yes pkg install -y $pkgs
    rc=$?
    # pkg install -y leaves out what it cannot install and still succeeds: the packages
    # that are missing afterwards go into the report (build-test-report.sh).
    mkdir -p "$res"
    for p in $pkgs; do pkg info -e "$p" || echo "$p"; done > "$res/deps-missing.txt"
    [ -s "$res/deps-missing.txt" ] && echo "build-test: packages not installed: $(tr '\n' ' ' < "$res/deps-missing.txt")"
    return $rc
}

# The CPU features of -march=$1 that this CPU has not (by the compiler's
# -march=native, as tools/config-check.sh and tools/build-deps.sh): code built for
# $1 stops here with "Illegal instruction".
cpu_lacks() {
    cpu_feats() {
        cc "-march=$1" -dM -E - < /dev/null 2>/dev/null |
            sed -n -E 's/^#define __(SSE4_2|POPCNT|AVX|AVX2|BMI|BMI2|FMA|F16C|LZCNT|MOVBE|AVX512F|AVX512BW|AVX512CD|AVX512DQ|AVX512VL)__ 1$/\1/p' |
            LC_ALL=C sort -u
    }
    mkdir -p "$work"
    cpu_feats "$1" > "$work/cpu-need"
    cpu_feats native > "$work/cpu-have"
    [ -s "$work/cpu-need" ] || { echo "?"; return 0; }
    LC_ALL=C comm -23 "$work/cpu-need" "$work/cpu-have" | tr '\n' ' ' | sed 's/ *$//'
}
# -march=x86-64-v3 as on the servers (CPUTYPE?=x86-64-v3 in make.conf), if this
# CPU runs it; else v2, so that the test binaries can run here.
v3_lacks="$(cpu_lacks x86-64-v3)"
if [ -z "$v3_lacks" ]; then march=x86-64-v3; else march=x86-64-v2; fi

if [ "${1:-}" = "--deps" ]; then
    shift
    deps "$@"
    exit $?
fi
# /usr/local/phpdeps of the level this CPU runs, from the tarballs of the release
# phpdeps-fbsd<major>-latest in $2 (phpdeps-fbsd<major>-amd64-v3.tar.xz, -v2).
if [ "${1:-}" = "--phpdeps" ]; then
    f="$(ls "${2:-.}"/phpdeps-fbsd*-amd64-"${march#x86-64-}".tar.xz 2>/dev/null | head -n 1)"
    [ -n "$f" ] || { echo "build-test: no phpdeps tarball for -march=$march in ${2:-.}" >&2; exit 1; }
    echo "build-test: extracting $f (this CPU runs -march=$march)"
    tar -xf "$f" -C /usr/local
    exit $?
fi
run_tests=0
if [ "${1:-}" = "--tests" ]; then
    run_tests=1
    shift
fi
[ $# -gt 0 ] || { sed -n 's/^# \{0,1\}//; 7,9p' "$0" >&2; exit 2; }

ncpu="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"

# Presets: the configure options of our servers, without the options of the
# ports framework (--build, build_alias, CPP=cpp, CPPFLAGS=), and with the bundled
# curl (--with-curl=bundled), as config-check.sh writes them on FreeBSD 14 and 15, and
# --with-openssl-legacy-provider (the option of PHP 8.4, here on every version).
# The environment is that of every PHP build here (tools/config-check.sh): CFLAGS
# and CXXFLAGS -O3 -pipe -march -fstack-protector-strong -fno-strict-aliasing, LIBS=-lpthread.
# 7.4 and newer bundle swoole and OpenSwoole, only one can be built into a PHP:
# SWOOLE=openswoole takes OpenSwoole. Likewise imagick or gmagick: MAGICK=gmagick.
preset() {
    sw=swoole
    [ "${SWOOLE:-swoole}" = openswoole ] && sw=openswoole
    mg=imagick
    [ "${MAGICK:-imagick}" = gmagick ] && mg=gmagick
    case "$1" in
        5.6)
            CFLAGS="-O3 -pipe -march=$march -fstack-protector-strong -fno-strict-aliasing"
            CXXFLAGS="$CFLAGS"
            LDFLAGS=""
            LIBS="-lpthread"
            set -- --prefix=/usr/local/php5640 --with-apxs2=/usr/local/sbin/apxs --disable-all \
                --with-layout=GNU --with-zend-vm=CALL --enable-libxml --with-libxml-dir=/usr/local \
                --enable-xml --enable-simplexml --with-regex=php --with-bz2 \
                --enable-ctype --with-curl=bundled --with-openssl-legacy-provider --enable-dom --enable-fileinfo --enable-filter --enable-ftp \
                --with-gd --with-jpeg-dir=/usr/local --with-png-dir=/usr/local \
                --with-freetype-dir=/usr/local --with-gettext --enable-hash --with-iconv=/usr/local \
                --enable-json --enable-mbstring --with-mcrypt=/usr/local --enable-pdo --with-pdo-mysql \
                --enable-mysqlnd --with-mysql --with-mysql-sock=/tmp/mysql.sock --with-mysqli \
                --enable-embedded-mysqli --enable-opcache --with-openssl=/usr --enable-phar \
                --enable-session --enable-tokenizer --with-xmlrpc --enable-xmlwriter --enable-zip \
                --with-zlib=/usr --enable-sockets \
                --enable-redis --enable-memcached --with-libmemcached-dir=/usr/local --disable-memcached-sasl \
                --enable-memcache --with-$mg=/usr/local \
                --enable-igbinary --enable-redis-igbinary --enable-memcached-igbinary \
                --enable-zend-signals
            ;;
        7.4)
            CFLAGS="-O3 -pipe -march=$march -fstack-protector-strong -fno-strict-aliasing"
            CXXFLAGS="$CFLAGS"
            LDFLAGS=""
            LIBS="-lpthread"
            set -- --with-layout=GNU --localstatedir=/var --disable-all --enable-ipv6 --with-libxml \
                --program-prefix= --enable-embed --enable-fpm --with-fpm-user=www --with-fpm-group=www \
                --prefix=/usr/local/php74 --mandir=/usr/local/php74/man --infodir=/usr/local/php74/info/ \
                --with-password-argon2=/usr/local --with-curl=bundled --with-bz2 --enable-dom \
                --with-readline=/usr/local --enable-filter --with-iconv=/usr/local --enable-json \
                --enable-ctype --enable-ftp --enable-mbstring --enable-opcache --enable-session \
                --enable-simplexml --enable-sockets --enable-tokenizer --enable-phar --enable-posix \
                --enable-xml --with-zip --with-zlib --enable-gd --with-external-gd --with-webp \
                --enable-mysqlnd --with-mysql-sock=/tmp/mysql.sock \
                --with-mysqli=mysqlnd --enable-pdo --with-pdo-mysql=mysqlnd --with-openssl --with-openssl-legacy-provider \
                --enable-redis --enable-memcached --with-libmemcached-dir=/usr/local --disable-memcached-sasl \
                --enable-memcache --with-$mg=/usr/local \
                --enable-igbinary --enable-redis-igbinary --enable-memcached-igbinary --enable-$sw \
                --enable-excimer --with-mcrypt=/usr/local
            ;;
        8.*)
            v="$(echo "$1" | tr -d .)"
            CFLAGS="-O3 -pipe -march=$march -fstack-protector-strong -fno-strict-aliasing"
            CXXFLAGS="$CFLAGS"
            LDFLAGS=""
            LIBS="-lpthread"
            set -- --with-apxs2=/usr/local/sbin/apxs --with-layout=GNU --localstatedir=/var --disable-all \
                --with-libxml --program-prefix= --enable-fpm --with-fpm-user=www --with-fpm-group=www \
                --prefix=/usr/local/php$v --mandir=/usr/local/php$v/man --infodir=/usr/local/php$v/info/ \
                --with-curl=bundled --enable-dom --with-readline=/usr/local --with-openssl=/usr --with-openssl-legacy-provider \
                --enable-filter --with-iconv=/usr/local --enable-ctype --enable-ftp --enable-mbstring \
                --enable-opcache --enable-opcache-jit --enable-phar --enable-session --enable-simplexml \
                --enable-xml --with-zlib --enable-gd --with-external-gd --with-webp \
                --enable-mysqlnd --with-mysql-sock=/tmp/mysql.sock \
                --with-mysqli=mysqlnd --enable-pdo --with-pdo-mysql=mysqlnd --enable-sockets \
                --enable-intl --enable-fileinfo --with-zip --enable-xmlwriter --enable-exif \
                --enable-redis --enable-memcached --with-libmemcached-dir=/usr/local --disable-memcached-sasl \
                --enable-memcache --with-$mg=/usr/local \
                --enable-igbinary --enable-redis-igbinary --enable-memcached-igbinary --enable-$sw \
                --enable-excimer --with-mcrypt=/usr/local
            ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$@" > "$out/configure-options.txt"
    if [ "${MAGICK:-imagick}" = none ]; then
        grep -v -E '^--with-(imagick|gmagick)(=|$)' "$out/configure-options.txt" > "$out/configure-options.new"
        mv "$out/configure-options.new" "$out/configure-options.txt"
    fi
    # EXTRA_CONFIGURE (the input "configure" of the workflow): more options for
    # every target, separated by spaces, such as --enable-zend-signals
    for o in ${EXTRA_CONFIGURE:-}; do printf '%s\n' "$o" >> "$out/configure-options.txt"; done
}

test_dirs() {
    case "$1" in
        5.6) echo "Zend/tests tests ext/standard/tests/strings ext/standard/tests/file ext/standard/tests/network
                   ext/libxml ext/dom ext/simplexml ext/xml ext/xmlwriter ext/xmlrpc ext/mbstring ext/pcre ext/json
                   ext/zlib ext/fileinfo ext/session ext/openssl ext/gd ext/iconv ext/mcrypt ext/tokenizer
                   ext/curl ext/zip ext/phar ext/sockets" ;;
        *) echo "Zend/tests tests ext/standard/tests/strings ext/standard/tests/file ext/standard/tests/network
                 ext/libxml ext/dom ext/simplexml ext/xml ext/xmlwriter ext/mbstring ext/pcre ext/json ext/zlib
                 ext/session ext/openssl ext/gd ext/iconv ext/tokenizer ext/curl ext/zip ext/phar ext/sockets
                 ext/posix ext/readline ext/intl" ;;
    esac
}

# Local memcached and redis for the smoke checks of the bundled PECL extensions.
# Fully detached (no inherited stdin/stdout/stderr), so that they cannot keep the
# SSH session of the VM open, and stopped again at the end.
if command -v memcached >/dev/null 2>&1; then
    memcached -d -u nobody -l 127.0.0.1 -p 11211 -P /tmp/build-test-memcached.pid </dev/null >/dev/null 2>&1 || true
fi
if command -v redis-server >/dev/null 2>&1; then
    redis-server --daemonize yes --bind 127.0.0.1 --port 6379 --pidfile /tmp/build-test-redis.pid </dev/null >/dev/null 2>&1 || true
fi
stop_servers() {
    for f in /tmp/build-test-memcached.pid /tmp/build-test-redis.pid; do
        if [ -f "$f" ]; then kill "$(cat "$f")" 2>/dev/null || true; rm -f "$f"; fi
    done
}
trap stop_servers EXIT INT TERM
# Progress on stdout (the details go to build-test-results/<target>/).
say() { printf '[build-test %s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

rc=0
for target in "$@"; do
    out="$res/$target"
    rm -rf "${out:?}" "${work:?}/$target"
    mkdir -p "$out" "$work/$target"
    sum="$out/summary.txt"
    say "$target: unpack and configure"
    tarball="$dist/php-$target-fbsd-latest.tar.xz"
    {
        echo "target:   $target"
        echo "host:     $(uname -sr), $(cc --version | head -1)"
        echo "cpu:      $(sysctl -n hw.model 2>/dev/null); -march=$march${v3_lacks:+ (lacks $v3_lacks of x86-64-v3)}"
        echo "openssl:  $(openssl version 2>/dev/null)"
        echo "libxml2:  $(pkg-config --modversion libxml-2.0 2>/dev/null)"
        echo "magick:   ImageMagick $(pkg-config --modversion MagickWand 2>/dev/null || echo missing), GraphicsMagick $(GraphicsMagick-config --version 2>/dev/null || echo missing)"
        echo "tarball:  ${tarball##*/} ($(sha256 -q "$tarball" 2>/dev/null | cut -c1-16)...)"
    } > "$sum"
    if [ ! -f "$tarball" ]; then
        echo "result:   FAIL (no tarball)" >> "$sum"; rc=1; continue
    fi
    tar -xf "$tarball" -C "$work/$target"
    src="$(ls -d "$work/$target"/php-* | head -1)"
    echo "source:   ${src##*/}" >> "$sum"
    if ! preset "$target"; then
        echo "result:   FAIL (no preset for $target)" >> "$sum"; rc=1; continue
    fi
    echo "CFLAGS:   $CFLAGS" >> "$sum"
    [ -n "${EXTRA_CONFIGURE:-}" ] && echo "extra:    $EXTRA_CONFIGURE" >> "$sum"
    cd "$src" || exit 1

    # shellcheck disable=SC2046
    # PHP against /usr/local/phpdeps (PHPDEPS_BUNDLE=1): the options and LDFLAGS as
    # config-check.sh writes them with the bundle installed, its pkg-config.
    pkgconfig="${PKG_CONFIG:-pkg-config}"
    if [ "${PHPDEPS_BUNDLE:-0}" = 1 ]; then
        printf "LDFLAGS='%s'\n" "$LDFLAGS" > "$out/env.txt"
        sh "$top/tools/config-check.sh" --deps-rewrite "$out/configure-options.txt" "$out/env.txt" > "$out/phpdeps-note.txt"
        LDFLAGS="$(sed -n "s/^LDFLAGS='\(.*\)'\$/\1/p" "$out/env.txt")"
        pkgconfig="$(sed -n "s/^PKG_CONFIG='\(.*\)'\$/\1/p" "$out/env.txt")"
        echo "phpdeps:  $(head -n 1 /usr/local/phpdeps/VERSIONS)" >> "$sum"
    fi
    if ! env CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS" LIBS="$LIBS" PKG_CONFIG="$pkgconfig" \
            ./configure $(cat "$out/configure-options.txt") > "$out/configure.log" 2>&1; then
        tail -n 40 "$out/configure.log" > "$out/configure-tail.txt"
        echo "result:   FAIL (configure: $(grep -i 'error' "$out/configure.log" | tail -1))" >> "$sum"
        say "$target: FAIL in configure: $(grep -i 'error' "$out/configure.log" | tail -1)"
        rc=1; cd "$top" || exit 1; continue
    fi
    tail -n 40 "$out/configure.log" > "$out/configure-tail.txt"
    cp config.log "$out/config.log" 2>/dev/null

    start=$(date +%s)
    say "$target: make -j$ncpu"
    make -k -j"$ncpu" > "$out/make.log" 2>&1
    mrc=$?
    echo "make:     exit $mrc, $(( $(date +%s) - start ))s, $(grep -c 'warning:' "$out/make.log") warnings" >> "$sum"
    # The include chain of the first error, then the errors, at most three per file,
    # so that one broken header repeated in every file that includes it does not hide
    # the rest; the ">>>" lines of a linker error (where a duplicate or undefined
    # symbol is defined and referenced) come with it.
    {
        grep -m 1 -B 8 ' error:' "$out/make.log" | grep -E '^In file included from|^ +from '
        awk '/ error:/ { split($0, a, ":"); ctx = 0; if (++n[a[1]] <= 3) { print; if ($0 ~ /^(ld|ld\.lld): error:/) ctx = 6 } next }
             /^>>> / { if (ctx > 0) { print; ctx-- } next }
             { ctx = 0 }
             /Error [0-9]+|\*\*\* Error code|undefined reference|cannot find|^make(\[[0-9]+\])?: / { print }' "$out/make.log" |
            awk '/^>>> / { print; next } !seen[$0]++'
    } | head -n 40 > "$out/errors.txt"
    # a failure without compiler errors (make itself, BSD make on a GNU-only construct): its last lines
    if [ ! -s "$out/errors.txt" ] && [ "$mrc" != 0 ]; then tail -n 20 "$out/make.log" > "$out/errors.txt"; fi
    if [ "$mrc" != 0 ] || [ ! -x sapi/cli/php ]; then
        echo "result:   FAIL (build; first errors in errors.txt)" >> "$sum"
        say "$target: FAIL in make: $(head -n 1 "$out/errors.txt")"
        rc=1; cd "$top" || exit 1; continue
    fi

    php="$src/sapi/cli/php"
    {
        echo "php -v:   $("$php" -n -v | head -1)"
        [ -x sapi/fpm/php-fpm ] && echo "fpm -v:   $(sapi/fpm/php-fpm -n -v | head -1)"
        # the file size (du counts the blocks on disk, on ZFS only those written out so
        # far: a module linked seconds before shows 1 KB)
        for so in libs/libphp*.so; do [ -f "$so" ] && echo "module:   $so ($(( $(wc -c < "$so") / 1024 )) KB)"; done
        echo "modules:  $("$php" -n -m | grep -v '^\[' | grep -v '^$' | tr '\n' ' ')"
        # the libraries of /usr/local the binaries load (none with phpdeps and MAGICK=none)
        echo "ldd:      $(ldd sapi/cli/php sapi/fpm/php-fpm libs/libphp*.so 2>/dev/null | awk '/=>/ { print $3 }' |
            grep '^/usr/local/' | sort -u | tr '\n' ' ' | sed 's/ *$//' | grep . || echo 'no library of /usr/local')"
        if [ "${PHPDEPS_BUNDLE:-0}" = 1 ]; then
            echo "curl:     $("$pkgconfig" --modversion libcurl) of /usr/local/phpdeps"
        fi
        if [ -f ext/curl/libcurl-build/VERSION ]; then
            echo "curl:     bundled $(cat ext/curl/libcurl-build/VERSION) (ext/curl/libcurl-build.log)"
            cp ext/curl/libcurl-build.log "$out/" 2>/dev/null
        fi
    } >> "$sum"
    opcache=""
    [ -f modules/opcache.so ] && opcache="-d zend_extension=$src/modules/opcache.so"
    # shellcheck disable=SC2086
    say "$target: smoke checks"
    legacy=0
    grep -qx -- --with-openssl-legacy-provider "$out/configure-options.txt" && legacy=1
    curl_v="$(cat ext/curl/libcurl-build/VERSION 2>/dev/null)"
    brotli_v="$(awk '$1 == "brotli" { print $2 }' ext/curl/libcurl-build/DEPS 2>/dev/null)"
    if [ "${PHPDEPS_BUNDLE:-0}" = 1 ]; then
        curl_v="$("$pkgconfig" --modversion libcurl 2>/dev/null)"
        brotli_v="$("$pkgconfig" --modversion libbrotlidec 2>/dev/null | sed 's/\.!=.*//')"
    fi
    env CURL_BUNDLED="$curl_v" CURL_BROTLI="$brotli_v" OPENSSL_LEGACY="$legacy" \
        "$php" -n $opcache "$top/tools/build-test-smoke.php" "$src" > "$out/smoke.txt" 2>&1
    echo "smoke:    $(grep -c '^ok ' "$out/smoke.txt") ok, $(grep -c '^FAIL ' "$out/smoke.txt") failed (smoke.txt)" >> "$sum"

    if [ "$run_tests" = 1 ]; then
        # Tests that never finish here and would stop the rest of the suite (the
        # run-tests.php of 5.6 has no time limit per test): stream_server_reneg_limit
        # runs "openssl s_client", which keeps the connection open, and the server of
        # the test waits for it to close.
        : > "$out/tests-left-out.txt"
        for t in ext/openssl/tests/stream_server_reneg_limit.phpt; do
            if [ -f "$t" ]; then mv "$t" "$t.left-out"; echo "$t" >> "$out/tests-left-out.txt"; fi
        done
        jobs=""
        "$php" -n run-tests.php --help 2>/dev/null | grep -q -- '-j<workers>' && jobs="-j$ncpu"
        # A time limit per target (TEST_TIME_LIMIT seconds; default 25 minutes, 60 for a
        # run-tests.php without parallel workers, as on 5.6), so that a slow or hanging
        # suite does not hold up the other targets; the counts then come from the
        # PASS/FAIL lines printed so far.
        limit="${TEST_TIME_LIMIT:-1500}"
        [ -n "$jobs" ] || limit="${TEST_TIME_LIMIT:-3600}"
        # shellcheck disable=SC2046,SC2086
        env NO_INTERACTION=1 REPORT_EXIT_STATUS=0 TEST_PHP_EXECUTABLE="$php" \
            timeout "$limit" \
            "$php" -n run-tests.php -q $jobs $opcache $(test_dirs "$target") > "$out/run-tests.log" < /dev/null 2>&1
        trc=$?
        if grep -q '^FAILED TEST SUMMARY' "$out/run-tests.log"; then
            sed -n '/^FAILED TEST SUMMARY/,/^=====/p' "$out/run-tests.log" | grep '\[' > "$out/tests.txt"
        else
            # without the summary: one result per line, colours and progress counters removed
            sed 's/\x1b\[[0-9;]*m//g' "$out/run-tests.log" | tr '\r' '\n' |
                sed -E 's/^TEST [0-9]+\/[0-9]+ \[[^]]*\] *//' > "$out/run-tests.lines"
            grep -E '^FAIL ' "$out/run-tests.lines" > "$out/tests.txt"
        fi
        if grep -q -E '^Tests (passed|failed)' "$out/run-tests.log"; then
            echo "tests:    $(grep -E '^Tests (passed|failed)' "$out/run-tests.log" | tr -s ' ' | tr '\n' ' ')" >> "$sum"
        else
            echo "tests:    stopped after ${limit}s (exit $trc): $(grep -c -E '^PASS ' "$out/run-tests.lines") passed, $(grep -c -E '^FAIL ' "$out/run-tests.lines") failed so far, last test started: $(sed 's/\x1b\[[0-9;]*m//g' "$out/run-tests.log" | tr '\r' '\n' | grep -o 'TEST [0-9]*/[0-9]* \[[^]]*\]' | tail -n 1)" >> "$sum"
        fi
    fi
    if [ "$run_tests" = 1 ] && [ -s "$out/tests-left-out.txt" ]; then
        echo "left out: $(tr '\n' ' ' < "$out/tests-left-out.txt")(they hang here)" >> "$sum"
    fi
    echo "result:   OK" >> "$sum"
    say "$target: OK ($(grep -c '^ok ' "$out/smoke.txt") smoke checks ok, $(grep -c '^FAIL ' "$out/smoke.txt") failed)"
    cd "$top" || exit 1
done
exit "$rc"
