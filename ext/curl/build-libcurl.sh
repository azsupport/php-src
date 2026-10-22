#!/bin/sh
# build-libcurl.sh - build ext/curl/libcurl for "configure --with-curl=bundled".
#
# Usage: sh ext/curl/build-libcurl.sh <prefix>
#
# ext/curl/config.m4 runs it with CC, CFLAGS, CPPFLAGS, LDFLAGS, PKG_CONFIG,
# OPENSSL_INCDIR and OPENSSL_CFLAGS of the PHP build and writes the output to
# <prefix>.log.
#
# libcurl is built static and position independent, so that it can go into php,
# php-fpm, php-cgi and libphp.so, against the OpenSSL of the PHP build (the base
# system one unless PHP is given another), with the options of the FreeBSD port
# ftp/curl minus the rarely used protocols: no DICT, Gopher, IPFS, MQTT, RTSP,
# Telnet, TFTP, LDAP, SCP/SFTP (libssh2) and GSSAPI. Needed packages: libnghttp2,
# brotli, zstd, libidn2, libpsl. <prefix> gets lib/libcurl.a, include/curl/,
# lib/pkgconfig/libcurl.pc and bin/curl-config; both print "-lcurl" with the
# libraries libcurl needs, the -L for <prefix>/lib is added by config.m4 to
# LDFLAGS (no run path into the build tree). A rerun with the same sources and
# flags keeps the build.

set -eu
prefix="$1"
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/libcurl"
obj="$prefix.obj"
pkgconf="${PKG_CONFIG:-pkg-config}"
ver="$(sed -n 's/^#define LIBCURL_VERSION "\(.*\)"$/\1/p' "$src/include/curl/curlver.h")"
ncpu="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 2)"

# The OpenSSL of the PHP build, as its configure found it: OPENSSL_INCDIR (PHP
# 5.6, from --with-openssl=<dir>), else the -I of OPENSSL_CFLAGS (PHP 7.4 and
# later, from pkg-config or the environment), else what pkg-config finds with the
# same environment, else the base system.
ossl_inc="${OPENSSL_INCDIR:-}"
if [ -z "$ossl_inc" ]; then
    ossl_inc="$(printf '%s\n' ${OPENSSL_CFLAGS:-} | sed -n 's/^-I//p' | head -n 1)"
fi
if [ -z "$ossl_inc" ]; then
    ossl_inc="$($pkgconf --variable=includedir openssl 2>/dev/null || true)"
fi
ossl_inc="${ossl_inc:-/usr/include}"
ossl_opt="--with-openssl=${ossl_inc%/include}"
if ! grep -q 'OPENSSL_VERSION_MAJOR' "$ossl_inc/openssl/opensslv.h" 2>/dev/null; then
    echo "curl $ver needs OpenSSL 3.0 or later (curl 8.18.0 dropped OpenSSL 1.1.1)," >&2
    echo "$ossl_inc/openssl/opensslv.h has:" \
        "$(sed -n 's/.*OPENSSL_VERSION_TEXT *"\([^"]*\)".*/\1/p' "$ossl_inc/openssl/opensslv.h" 2>/dev/null | head -n 1)" >&2
    echo "FreeBSD 13.x (OpenSSL 1.1.1 in base): build with --with-curl, libcurl from pkg." >&2
    exit 1
fi

stamp="curl $ver | $ossl_opt | ${CC:-cc} | ${CFLAGS:-} | ${CPPFLAGS:-} | ${LDFLAGS:-} | $(cksum < "$0")"
if [ -f "$prefix/lib/libcurl.a" ] && [ "$(cat "$prefix/.stamp" 2>/dev/null)" = "$stamp" ]; then
    echo "libcurl $ver: built before with the same flags, kept: $prefix"
    exit 0
fi
rm -rf "$prefix" "$obj"
mkdir -p "$obj"
cd "$obj"

# The configure options follow freebsd-ports ftp/curl (CONFIGURE_ARGS and the
# default OPTIONS); ac_cv_func_SSLv2_client_method=no is from its CONFIGURE_ENV.
ac_cv_func_SSLv2_client_method=no \
"$src/configure" --prefix="$prefix" --libdir="$prefix/lib" \
    --disable-shared --enable-static --with-pic --disable-dependency-tracking \
    "$ossl_opt" --enable-openssl-auto-load-config \
    --with-ca-path=/etc/ssl/certs --without-ca-bundle \
    --with-nghttp2 --with-brotli --with-zstd --with-libidn2 --with-libpsl \
    --enable-http --enable-ftp --enable-imap --enable-pop3 --enable-smtp \
    --enable-proxy --enable-cookies --enable-alt-svc --enable-hsts --enable-ntlm \
    --enable-websockets --enable-ipv6 --enable-threaded-resolver \
    --enable-aws --enable-dateparse --enable-dnsshuffle --enable-headers-api \
    --enable-http-auth --enable-mime --enable-netrc --enable-progress-meter \
    --enable-ssls-export --enable-typecheck \
    --disable-httpsig --disable-unity --disable-werror \
    --disable-dict --disable-gopher --disable-ipfs --disable-mqtt --disable-rtsp \
    --disable-telnet --disable-tftp --disable-ldap --disable-ldaps \
    --without-gssapi --without-libssh2 --without-libssh \
    --disable-manual --disable-docs \
    --without-zsh-functions-dir --without-fish-functions-dir

make -j"$ncpu" -C lib
make -C lib install
make -C include install
make install-pkgconfigDATA install-binSCRIPTS
# Only libcurl.a: without libcurl.la libtool passes -lcurl on as it is.
rm -f "$prefix/lib/libcurl.la"

# The link line: libcurl.a and the shared libraries it needs (a static-only curl
# lists them in Libs and Requires already), without the -L of the prefix, which
# config.m4 puts into LDFLAGS, so that PHP records no run path into the build tree.
# It goes into Libs as it is; Requires and the private lines go, so that nothing
# comes twice.
libs="$(PKG_CONFIG_PATH="$prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
    $pkgconf --libs libcurl | tr ' ' '\n' | grep -v -x -e "-L$prefix/lib" -e '' | tr '\n' ' ')"
pc="$prefix/lib/pkgconfig/libcurl.pc"
sed -e "s|^Libs:.*|Libs: ${libs% }|" -e '/^Libs.private:/d' -e '/^Requires/d' "$pc" > "$pc.new"
mv "$pc.new" "$pc"
mv "$prefix/bin/curl-config" "$prefix/bin/curl-config.orig"
cat > "$prefix/bin/curl-config" <<EOF
#!/bin/sh
# curl-config of the bundled libcurl: --libs gives the static link line.
case "\$1" in
    --libs|--static-libs) echo "${libs% }" ;;
    *) exec "$prefix/bin/curl-config.orig" "\$@" ;;
esac
EOF
chmod +x "$prefix/bin/curl-config"

echo "$ver" > "$prefix/VERSION"
echo "$stamp" > "$prefix/.stamp"
echo "libcurl $ver built: $prefix ($ossl_opt; ${libs% })"
