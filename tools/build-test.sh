#!/bin/sh
# build-test.sh - build the release tarballs on FreeBSD with the ./configure
# options our servers use, and check the result. The GitHub workflow
# .github/workflows/build-test.yml runs it in a FreeBSD VM; it works the same on
# a FreeBSD server.
#
# Usage (from the top of a php-src checkout of master):
#   sh tools/build-test.sh --deps 5.6 7.4        install the packages the presets need
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
    # libmemcached, ImageMagick7-nox11: bundled PECL memcached and imagick; memcached and
    # redis: servers for the smoke checks of the PECL extensions
    pkgs="pkgconf libmemcached ImageMagick7-nox11 memcached redis brotli"
    for t in "$@"; do
        case "$t" in
            5.6) pkgs="$pkgs libxml2 curl jpeg-turbo png freetype2 gettext-runtime libiconv libmcrypt pcre apache24 perl5" ;;
            7.4) pkgs="$pkgs libxml2 curl libargon2 readline libiconv libzip libgd webp pcre2 oniguruma" ;;
            8.*) pkgs="$pkgs libxml2 curl readline libiconv libzip libgd webp pcre2 oniguruma icu apache24 perl5" ;;
        esac
    done
    # shellcheck disable=SC2086
    env ASSUME_ALWAYS_YES=yes pkg install -y $pkgs
}

if [ "${1:-}" = "--deps" ]; then
    shift
    deps "$@"
    exit $?
fi
run_tests=0
if [ "${1:-}" = "--tests" ]; then
    run_tests=1
    shift
fi
[ $# -gt 0 ] || { sed -n 's/^# \{0,1\}//; 7,9p' "$0" >&2; exit 2; }

ncpu="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
# -march=x86-64-v3 as on the servers (CPUTYPE?=x86-64-v3 in make.conf), if this
# CPU has AVX2; else v2, so the test binaries can run here.
if grep -q AVX2 /var/run/dmesg.boot 2>/dev/null; then march=x86-64-v3; else march=x86-64-v2; fi

# Presets: the configure options of our servers, without the options of the
# ports framework (--build, build_alias, CPP=cpp, CPPFLAGS=).
preset() {
    case "$1" in
        5.6)
            CFLAGS="-O3 -pipe -march=$march -fstack-protector -fno-strict-aliasing"
            CXXFLAGS="$CFLAGS"
            LDFLAGS="-fstack-protector"
            LIBS="-lpthread"
            set -- --prefix=/usr/local/php5640 --with-apxs2=/usr/local/sbin/apxs --disable-all \
                --with-layout=GNU --with-zend-vm=CALL --enable-libxml --with-libxml-dir=/usr/local \
                --enable-xml --enable-simplexml --with-regex=php --with-pcre-regex=/usr/local --with-bz2 \
                --enable-ctype --with-curl --enable-dom --enable-fileinfo --enable-filter --enable-ftp \
                --with-gd --with-jpeg-dir=/usr/local --with-png-dir=/usr/local \
                --with-freetype-dir=/usr/local --with-gettext --enable-hash --with-iconv=/usr/local \
                --enable-json --enable-mbstring --with-mcrypt=/usr/local --enable-pdo --with-pdo-mysql \
                --enable-mysqlnd --with-mysql --with-mysql-sock=/tmp/mysql.sock --with-mysqli \
                --enable-embedded-mysqli --enable-opcache --with-openssl=/usr --enable-phar \
                --enable-session --enable-tokenizer --with-xmlrpc --enable-xmlwriter --enable-zip \
                --with-zlib=/usr --enable-sockets \
                --enable-redis --enable-memcached --with-libmemcached-dir=/usr/local --disable-memcached-sasl \
                --enable-memcache --with-imagick=/usr/local \
                --enable-igbinary --enable-redis-igbinary --enable-memcached-igbinary
            ;;
        7.4)
            CFLAGS="-O3 -pipe -march=$march -fstack-protector-strong -fno-strict-aliasing"
            CXXFLAGS="$CFLAGS"
            LDFLAGS=""
            LIBS=""
            set -- --with-layout=GNU --localstatedir=/var --disable-all --enable-ipv6 --with-libxml \
                --program-prefix= --enable-embed --enable-fpm --with-fpm-user=www --with-fpm-group=www \
                --prefix=/usr/local/php74 --mandir=/usr/local/php74/man --infodir=/usr/local/php74/info/ \
                --with-password-argon2=/usr/local --with-curl=/usr/local --with-bz2 --enable-dom \
                --with-readline=/usr/local --enable-filter --with-iconv=/usr/local --enable-json \
                --enable-ctype --enable-ftp --enable-mbstring --enable-opcache --enable-session \
                --enable-simplexml --enable-sockets --enable-tokenizer --enable-phar --enable-posix \
                --enable-xml --with-zip --with-zlib --enable-gd --with-external-gd --with-webp \
                --with-external-pcre=/usr/local --enable-mysqlnd --with-mysql-sock=/tmp/mysql.sock \
                --with-mysqli=mysqlnd --enable-pdo --with-pdo-mysql=mysqlnd --with-openssl \
                --enable-redis --enable-memcached --with-libmemcached-dir=/usr/local --disable-memcached-sasl \
                --enable-memcache --with-imagick=/usr/local \
                --enable-igbinary --enable-redis-igbinary --enable-memcached-igbinary --enable-swoole
            ;;
        8.*)
            v="$(echo "$1" | tr -d .)"
            CFLAGS="-O3 -pipe -march=$march -fstack-protector -fno-strict-aliasing"
            CXXFLAGS="-std=c++17 $CFLAGS"
            LDFLAGS=""
            LIBS=""
            set -- --with-apxs2=/usr/local/sbin/apxs --with-layout=GNU --localstatedir=/var --disable-all \
                --with-libxml --program-prefix= --enable-fpm --with-fpm-user=www --with-fpm-group=www \
                --prefix=/usr/local/php$v --mandir=/usr/local/php$v/man --infodir=/usr/local/php$v/info/ \
                --with-curl=/usr/local --enable-dom --with-readline=/usr/local --with-openssl=/usr \
                --enable-filter --with-iconv=/usr/local --enable-ctype --enable-ftp --enable-mbstring \
                --enable-opcache --enable-opcache-jit --enable-phar --enable-session --enable-simplexml \
                --enable-xml --with-zlib --enable-gd --with-external-gd --with-webp \
                --with-external-pcre=/usr/local --enable-mysqlnd --with-mysql-sock=/tmp/mysql.sock \
                --with-mysqli=mysqlnd --enable-pdo --with-pdo-mysql=mysqlnd --enable-sockets \
                --enable-intl --enable-fileinfo --with-zip --enable-xmlwriter --enable-exif \
                --enable-redis --enable-memcached --with-libmemcached-dir=/usr/local --disable-memcached-sasl \
                --enable-memcache --with-imagick=/usr/local \
                --enable-igbinary --enable-redis-igbinary --enable-memcached-igbinary --enable-swoole
            ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$@" > "$out/configure-options.txt"
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
        echo "openssl:  $(openssl version 2>/dev/null)"
        echo "libxml2:  $(pkg-config --modversion libxml-2.0 2>/dev/null)"
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
    cd "$src" || exit 1

    # shellcheck disable=SC2046
    if ! env CFLAGS="$CFLAGS" CXXFLAGS="$CXXFLAGS" LDFLAGS="$LDFLAGS" LIBS="$LIBS" \
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
    grep -E ' error:|Error [0-9]+|undefined reference|cannot find' "$out/make.log" | head -n 40 > "$out/errors.txt"
    if [ "$mrc" != 0 ] || [ ! -x sapi/cli/php ]; then
        echo "result:   FAIL (build; first errors in errors.txt)" >> "$sum"
        say "$target: FAIL in make: $(head -n 1 "$out/errors.txt")"
        rc=1; cd "$top" || exit 1; continue
    fi

    php="$src/sapi/cli/php"
    {
        echo "php -v:   $("$php" -n -v | head -1)"
        [ -x sapi/fpm/php-fpm ] && echo "fpm -v:   $(sapi/fpm/php-fpm -n -v | head -1)"
        for so in libs/libphp*.so; do [ -f "$so" ] && echo "module:   $so ($(du -k "$so" | cut -f1) KB)"; done
        echo "modules:  $("$php" -n -m | grep -v '^\[' | grep -v '^$' | tr '\n' ' ')"
    } >> "$sum"
    opcache=""
    [ -f modules/opcache.so ] && opcache="-d zend_extension=$src/modules/opcache.so"
    # shellcheck disable=SC2086
    say "$target: smoke checks"
    "$php" -n $opcache "$top/tools/build-test-smoke.php" "$src" > "$out/smoke.txt" 2>&1
    echo "smoke:    $(grep -c '^ok ' "$out/smoke.txt") ok, $(grep -c '^FAIL ' "$out/smoke.txt") failed (smoke.txt)" >> "$sum"

    if [ "$run_tests" = 1 ]; then
        jobs=""
        "$php" -n run-tests.php --help 2>/dev/null | grep -q -- '-j<workers>' && jobs="-j$ncpu"
        # A time limit per target (TEST_TIME_LIMIT seconds, default 25 minutes), so that
        # a slow or hanging suite does not hold up the other targets; the counts then
        # come from the PASS/FAIL lines printed so far.
        # shellcheck disable=SC2046,SC2086
        env NO_INTERACTION=1 REPORT_EXIT_STATUS=0 TEST_PHP_EXECUTABLE="$php" \
            timeout "${TEST_TIME_LIMIT:-1500}" \
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
            echo "tests:    stopped after ${TEST_TIME_LIMIT:-1500}s (exit $trc): $(grep -c -E '^PASS ' "$out/run-tests.lines") passed, $(grep -c -E '^FAIL ' "$out/run-tests.lines") failed so far" >> "$sum"
        fi
    fi
    echo "result:   OK" >> "$sum"
    say "$target: OK ($(grep -c '^ok ' "$out/smoke.txt") smoke checks ok, $(grep -c '^FAIL ' "$out/smoke.txt") failed)"
    cd "$top" || exit 1
done
exit "$rc"
