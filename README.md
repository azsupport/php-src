<!-- freebsd-notes:start -->
> [!IMPORTANT]
> **This is `azsupport/php-src`, branch `freebsd/7.4`: not an official PHP release.**
>
> PHP 7.4 is end-of-life upstream. This branch follows Remi Collet's community security backports ([remicollet/php-src-security](https://github.com/remicollet/php-src-security), branch `PHP-7.4-security-backports`) and adds a few FreeBSD ports patches, for building PHP 7.4 by hand on FreeBSD.
>
> | | |
> |---|---|
> | Upstream | [remicollet/php-src-security `PHP-7.4-security-backports`](https://github.com/remicollet/php-src-security/tree/PHP-7.4-security-backports) @ `802c21075308` |
> | PHP version | 7.4.33 (`phpversion()` unchanged); `php -v` adds `(fork: 20261021-fbsd-802c2107)` |
> | FreeBSD patches | from freebsd-ports `lang/php74` @ `036685c034ba`: applied and not applied, below |
> | Ready-to-build tarball | [freebsd-7.4-latest](https://github.com/azsupport/php-src/releases/tag/freebsd-7.4-latest): `configure` and parsers are pre-generated, no autoconf/bison/re2c needed |
> | Updated | 21.10.2026 (UTC), automatically by [tools/sync.sh](https://github.com/azsupport/php-src/blob/HEAD/tools/sync.sh) |
>
> **FreeBSD ports patches** from freebsd-ports [`lang/php74` @ `036685c034ba`](https://github.com/freebsd/freebsd-ports/tree/036685c034ba/lang/php74/files):
>
> **Applied** (commit "Apply curated FreeBSD ports patches"):
>
> - `patch-build_Makefile.global` (`build/Makefile.global`): 'make install' does not fail when no php.ini is present.
> - `patch-sapi_apache2handler_config.m4` (`sapi/apache2handler/config.m4`): 'make install' installs the module without editing httpd.conf (no apxs -a).
> - `patch-sapi_fpm_config.m4` (`sapi/fpm/config.m4`): Report the listen queue via SO_LISTENQLEN; FreeBSD's struct tcp_info lacks the Linux fields.
> - `patch-sapi_fpm_www.conf.in` (`sapi/fpm/www.conf.in`): Document that IPv4-mapped addresses are disabled by default on FreeBSD.
>
> **Not applied:**
>
> - `patch-configure.ac`: ports build layout: makes php_config.h include ext/php_config.h, which only the port's Makefile creates (a hand build fails without it), drops the configure pthreads check and sets the ports' PEAR include_path
> - `patch-ext_mysqli_mysqli__api.c`, `patch-ext_mysqli_mysqli__nonapi.c`, `patch-ext_mysqli_mysqli__prop.c`, `patch-ext_mysqli_php__mysqli__structs.h`: ports split packaging of ext/mysqli (built alone with phpize, where the ext/mysqlnd headers are missing); not needed when building from the full source tree
> - `patch-ext_pcre_pcre2lib_sljit_sljitConfigInternal.h`: PowerPC 32-bit only; no effect on amd64
> - `php-fpm.in`: the rc.d script of the port, not a source patch; your own rc.d scripts stay in use
>
> **Build compatibility patches by azsupport** (commit "Apply build compatibility patches"):
>
> - `compat-c99.patch`: Fix configure test programs that clang 16 and newer (FreeBSD 14/15 base: clang 19) and gcc 14 and newer reject for their implicit int return type, so they failed silently: whether write(2) to stdout works (the CLI then wrote through stdio instead of write(2)), the run check of PHP_CHECK_FUNC_LIB (functions found only in a separate library) and the reentrant time function type. The sources need no change for those compilers. (azsupport; configure results checked against a run with those errors turned into warnings: identical main/php_config.h)
> - `compat-openssl3.patch`: Build and run against OpenSSL 3 (FreeBSD 14/15 base): guard OPENSSL_SSLV23_PADDING (gone in OpenSSL 3), load the legacy provider for RC4 (the default of openssl_seal()), Blowfish, DES, RC2, CAST5 and MD4, and return only the public part from openssl_csr_get_public_key(). No change with OpenSSL 1.1. (azsupport; padding guard and CSR public key extraction as in php-src PHP-8.1 ext/openssl/openssl.c, provider loading per OSSL_PROVIDER_load(3); tested against OpenSSL 3.5.6)
>
> **Bundled PECL extensions** (commit "Bundle PECL extensions"), built only when enabled with their option:
>
> - redis 6.3.0 ([phpredis/phpredis @ `df4fab2de7fc`](https://github.com/phpredis/phpredis/tree/df4fab2de7fc327c54c94a13af2b9542e4fbd720)): `--enable-redis`
> - memcached 3.4.0 ([php-memcached-dev/php-memcached @ `ce37962769fc`](https://github.com/php-memcached-dev/php-memcached/tree/ce37962769fc7b25f9905c4b23fa53df92447a32)): `--enable-memcached --with-libmemcached-dir=/usr/local --disable-memcached-sasl` (package `libmemcached`)
> - memcache 4.0.5.2 ([websupport-sk/pecl-memcache @ `5d719ce25804`](https://github.com/websupport-sk/pecl-memcache/tree/5d719ce25804f5fff78594c8c2d769fc6c560b65)): `--enable-memcache`; patch `memcache-4.0.5.2.patch`: Build inside php-src as ext/memcache (bundled by this fork), not only with phpize: config9.m4 looked for its php7/ sources under abs_srcdir, which is the PHP tree there, and its PHP version test could not find php_version.h, so configure stopped ("checking PHP version... unknown"); main/internal_functions.c needs ext/memcache/php_memcache.h for phpext_memcache_ptr. config9.m4 now uses PHP_EXT_SRCDIR(memcache), the extension directory in both cases, adds main/ for the version test, and a top-level php_memcache.h includes php7/php_memcache.h.
> - imagick 3.8.1 ([Imagick/imagick @ `70087bab33ea`](https://github.com/Imagick/imagick/tree/70087bab33eab913e99ac77d64d04d1a2fd0b7b0)): `--with-imagick=/usr/local` (package `ImageMagick7` or `ImageMagick7-nox11`); patch `imagick-3.8.1.patch`: Build inside php-src as ext/imagick (bundled by this fork): buildconf runs in the top of the PHP tree, where m4_include of imagemagick.m4 finds no file, so config.m4 now includes ext/imagick/imagemagick.m4; and set the version that PECL packaging fills in ("@PACKAGE_VERSION@" in the git sources) to 3.8.1, for phpversion('imagick').
> - igbinary 3.2.16 ([igbinary/igbinary @ `8326f6a69ebb`](https://github.com/igbinary/igbinary/tree/8326f6a69ebb30dd6258dd536eb0914454fbf146)): `--enable-igbinary`; the igbinary serializer of redis and memcached: `--enable-redis-igbinary`, `--enable-memcached-igbinary`
> - swoole 4.8.13 ([swoole/swoole-src @ `48c8a40b5059`](https://github.com/swoole/swoole-src/tree/48c8a40b5059d4793b31b7646f8e2b1483af14b2)): `--enable-swoole` (OpenSSL when PHP is built `--with-openssl`; brotli compression with the package `brotli`); patch `swoole-4.8.13.patch`: Build inside php-src as ext/swoole (bundled by this fork): the default of --enable-swoole was "yes", which built it into every PHP configured without --disable-all; it is now "no"; drop the option --enable-openssl, which reset PHP_OPENSSL of --with-openssl to "no" so that mysqlnd built without its OpenSSL code (swoole now uses OpenSSL when PHP is built --with-openssl, as swoole 6.2 does); drop the -std=c++11 that config.m4 appends to CXXFLAGS, which inside php-src applies to every C++ file and overrides the C++17 that ext/intl needs with ICU 75 and newer.
> - openswoole 4.12.1 ([openswoole/ext-openswoole @ `b4a458b59e18`](https://github.com/openswoole/ext-openswoole/tree/b4a458b59e1805fd2201b331225ecbce85954dc6)): `--enable-openswoole` (OpenSwoole 4.x API; OpenSSL when PHP is built `--with-openssl`; not together with swoole); patch `openswoole-4.12.1.patch`: Build inside php-src as ext/openswoole (bundled by this fork): configure built OpenSwoole into every PHP, as it tested PHP_SWOOLE (left over from swoole, unset there) instead of PHP_OPENSWOOLE, and the default of --enable-openswoole was "yes"; now only --enable-openswoole builds it, and configure stops when --enable-swoole is given too (same C++ symbols). Drop the option --enable-openssl, which reset PHP_OPENSSL of --with-openssl to "no" so that mysqlnd built without its OpenSSL code (OpenSwoole now uses OpenSSL when PHP is built --with-openssl, as swoole 6.2 does); drop the -std=c++11 that config.m4 appends to CXXFLAGS, which inside php-src applies to every C++ file and overrides the C++17 that ext/intl needs with ICU 75 and newer; and include <stdint.h> in swoole_proxy.h, which uses uint8_t (unknown type name with clang 19).
>
> The upstream `.github/` CI configuration is removed so that php-src CI does not
> run in this fork. Provided as is, without warranty.

The original PHP README follows.
<!-- freebsd-notes:end -->

# Sources

This is a fork of the official PHP repository which receives backport of security fixes from maintained branches.

This branch is **PHP version 7.4.33** with security fixes (see the NEWS file).

# Binary distributions

Known list of providers using this repository as sources for build of old PHP version with extended security support:

## RPM

### Fedora / RHEL / CentOS / AlmaLinux / RockyLinux

* [Remi's RPM repository](https://rpms.remirepo.net/)

## DEB

### Debian / Ubuntu

* [DEB.SURY.ORG](https://deb.sury.org) - Debian [stable](https://wiki.debian.org/DebianStable) and [oldstable](https://wiki.debian.org/DebianOldStable); Ubuntu [LTS](https://ubuntu.com/about/release-cycle)
* [PHP LTS by Freexian](https://www.freexian.com/lts/php/) - Debian [LTS](https://wiki.debian.org/LTS) and [ELTS](https://wiki.debian.org/LTS/Extended) releases; Ubuntu [LTS](https://ubuntu.com/about/release-cycle) and [ESM](https://ubuntu.com/security/esm) releases
