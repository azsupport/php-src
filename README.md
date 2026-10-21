<!-- freebsd-notes:start -->
> [!IMPORTANT]
> **This is `azsupport/php-src`, branch `freebsd/8.1`: not an official PHP release.**
>
> PHP 8.1 is end-of-life upstream. This branch follows Remi Collet's community security backports ([remicollet/php-src-security](https://github.com/remicollet/php-src-security), branch `PHP-8.1-security-backports`) and adds a few FreeBSD ports patches, for building PHP 8.1 by hand on FreeBSD.
>
> | | |
> |---|---|
> | Upstream | [remicollet/php-src-security `PHP-8.1-security-backports`](https://github.com/remicollet/php-src-security/tree/PHP-8.1-security-backports) @ `1e06d14cdc77` |
> | PHP version | 8.1.34 (`phpversion()` unchanged); `php -v` adds `(fork: 20261021-fbsd-1e06d14c)` |
> | FreeBSD patches | from freebsd-ports `lang/php81` @ `6002588334a9`: applied and not applied, below |
> | Ready-to-build tarball | [freebsd-8.1-latest](https://github.com/azsupport/php-src/releases/tag/freebsd-8.1-latest): `configure` and parsers are pre-generated, no autoconf/bison/re2c needed |
> | Updated | 21.10.2026 (UTC), automatically by [tools/sync.sh](https://github.com/azsupport/php-src/blob/HEAD/tools/sync.sh) |
>
> **FreeBSD ports patches** from freebsd-ports [`lang/php81` @ `6002588334a9`](https://github.com/freebsd/freebsd-ports/tree/6002588334a9/lang/php81/files):
>
> **Applied** (commit "Apply curated FreeBSD ports patches"):
>
> - `patch-TSRM_TSRM.c` (`TSRM/TSRM.c`): Do not use the Linux aarch64 TLS assembly on FreeBSD (no effect on amd64).
> - `patch-build_Makefile.global` (`build/Makefile.global`): 'make install' does not fail when no php.ini is present.
> - `patch-sapi_apache2handler_config.m4` (`sapi/apache2handler/config.m4`): 'make install' installs the module without editing httpd.conf (no apxs -a).
> - `patch-sapi_fpm_config.m4` (`sapi/fpm/config.m4`): Report the listen queue via SO_LISTENQLEN; FreeBSD's struct tcp_info lacks the Linux fields.
> - `patch-sapi_fpm_www.conf.in` (`sapi/fpm/www.conf.in`): Document that IPv4-mapped addresses are disabled by default on FreeBSD.
>
> **Not applied:**
>
> - `patch-configure.ac`: ports build layout: makes php_config.h include ext/php_config.h, which only the port's Makefile creates (a hand build fails without it), drops the configure pthreads check and sets the ports' PEAR include_path
> - `patch-ext_hash_xxhash_xxhash.h`: PowerPC VSX (AltiVec) and s390x only; no effect on amd64
> - `patch-ext_mysqli_mysqli__api.c`, `patch-ext_mysqli_mysqli__nonapi.c`, `patch-ext_mysqli_mysqli__prop.c`, `patch-ext_mysqli_php__mysqli__structs.h`: ports split packaging of ext/mysqli (built alone with phpize, where the ext/mysqlnd headers are missing); not needed when building from the full source tree
> - `patch-ext_pcre_pcre2lib_sljit_sljitConfigInternal.h`: PowerPC 32-bit only; no effect on amd64
> - `php_fpm.in`: the rc.d script of the port, not a source patch; your own rc.d scripts stay in use
>
> **Bundled PECL extensions** (commit "Bundle PECL extensions"), built only when enabled with their option:
>
> - redis 6.3.0 ([phpredis/phpredis @ `df4fab2de7fc`](https://github.com/phpredis/phpredis/tree/df4fab2de7fc327c54c94a13af2b9542e4fbd720)): `--enable-redis`
> - memcached 3.4.0 ([php-memcached-dev/php-memcached @ `ce37962769fc`](https://github.com/php-memcached-dev/php-memcached/tree/ce37962769fc7b25f9905c4b23fa53df92447a32)): `--enable-memcached --with-libmemcached-dir=/usr/local --disable-memcached-sasl` (package `libmemcached`)
> - memcache 8.2 ([websupport-sk/pecl-memcache @ `05db30910e79`](https://github.com/websupport-sk/pecl-memcache/tree/05db30910e791b3841587d18a4e37b4cb6aa04c3)): `--enable-memcache`; patch `memcache-8.2.patch`: Build inside php-src as ext/memcache (bundled by this fork), not only with phpize: config9.m4 looked for its src/ sources under abs_srcdir, which is the PHP tree there, and its PHP version test could not find php_version.h, so configure stopped ("checking PHP version... unknown"); main/internal_functions.c needs ext/memcache/php_memcache.h for phpext_memcache_ptr. config9.m4 now uses PHP_EXT_SRCDIR(memcache), the extension directory in both cases, adds main/ for the version test, and a top-level php_memcache.h includes src/php_memcache.h.
> - imagick 3.8.1 ([Imagick/imagick @ `70087bab33ea`](https://github.com/Imagick/imagick/tree/70087bab33eab913e99ac77d64d04d1a2fd0b7b0)): `--with-imagick=/usr/local` (package `ImageMagick7` or `ImageMagick7-nox11`); patch `imagick-3.8.1.patch`: Build inside php-src as ext/imagick (bundled by this fork): buildconf runs in the top of the PHP tree, where m4_include of imagemagick.m4 finds no file, so config.m4 now includes ext/imagick/imagemagick.m4; and set the version that PECL packaging fills in ("@PACKAGE_VERSION@" in the git sources) to 3.8.1, for phpversion('imagick').
> - igbinary 3.2.16 ([igbinary/igbinary @ `8326f6a69ebb`](https://github.com/igbinary/igbinary/tree/8326f6a69ebb30dd6258dd536eb0914454fbf146)): `--enable-igbinary`; the igbinary serializer of redis and memcached: `--enable-redis-igbinary`, `--enable-memcached-igbinary`
> - swoole 6.1.10 ([swoole/swoole-src @ `c4e2d2ae34e2`](https://github.com/swoole/swoole-src/tree/c4e2d2ae34e2fe203e30b9135a62399d12a53117)): `--enable-swoole` (OpenSSL when PHP is built `--with-openssl`; brotli compression with the package `brotli`); patch `swoole-6.1.10.patch`: Build inside php-src as ext/swoole (bundled by this fork): the default of --enable-swoole was "yes", which built it into every PHP configured without --disable-all; it is now "no"; drop the option --enable-openssl, which reset PHP_OPENSSL of --with-openssl to "no" so that mysqlnd built without its OpenSSL code (swoole now uses OpenSSL when PHP is built --with-openssl, as swoole 6.2 does); drop the -std=c++14 that config.m4 appends to CXXFLAGS, which inside php-src applies to every C++ file and overrides the C++17 that ext/intl needs with ICU 75 and newer.
> - openswoole 4.12.1 ([openswoole/ext-openswoole @ `b4a458b59e18`](https://github.com/openswoole/ext-openswoole/tree/b4a458b59e1805fd2201b331225ecbce85954dc6)): `--enable-openswoole` (OpenSwoole 4.x API; OpenSSL when PHP is built `--with-openssl`; not together with swoole); patch `openswoole-4.12.1.patch`: Build inside php-src as ext/openswoole (bundled by this fork): configure built OpenSwoole into every PHP, as it tested PHP_SWOOLE (left over from swoole, unset there) instead of PHP_OPENSWOOLE, and the default of --enable-openswoole was "yes"; now only --enable-openswoole builds it, and configure stops when --enable-swoole is given too (same C++ symbols). Drop the option --enable-openssl, which reset PHP_OPENSSL of --with-openssl to "no" so that mysqlnd built without its OpenSSL code (OpenSwoole now uses OpenSSL when PHP is built --with-openssl, as swoole 6.2 does); drop the -std=c++11 that config.m4 appends to CXXFLAGS, which inside php-src applies to every C++ file and overrides the C++17 that ext/intl needs with ICU 75 and newer; and include <stdint.h> in swoole_proxy.h, which uses uint8_t (unknown type name with clang 19).
>
> The upstream `.github/` CI configuration is removed so that php-src CI does not
> run in this fork. Provided as is, without warranty.

The original PHP README follows.
<!-- freebsd-notes:end -->

# Sources

This is a fork of the official PHP repository which receives backport of security fixes from maintained branches.

This branch is **PHP version 8.1.34** with security fixes (see the NEWS file).

# Binary distributions

Known list of providers using this repository as sources for build of old PHP version with extended security support:

## RPM

### Fedora / RHEL / CentOS / AlmaLinux / RockyLinux

* [Remi's RPM repository](https://rpms.remirepo.net/)

## DEB

### Debian / Ubuntu

* [DEB.SURY.ORG](https://deb.sury.org) - Debian [stable](https://wiki.debian.org/DebianStable) and [oldstable](https://wiki.debian.org/DebianOldStable); Ubuntu [LTS](https://ubuntu.com/about/release-cycle)
* [PHP LTS by Freexian](https://www.freexian.com/lts/php/) - Debian [LTS](https://wiki.debian.org/LTS) and [ELTS](https://wiki.debian.org/LTS/Extended) releases; Ubuntu [LTS](https://ubuntu.com/about/release-cycle) and [ESM](https://ubuntu.com/security/esm) releases
