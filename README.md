<!-- freebsd-notes:start -->
> [!IMPORTANT]
> **This is `azsupport/php-src`, branch `freebsd/7.4`: not an official PHP release.**
>
> PHP 7.4 is end-of-life upstream. This branch follows Remi Collet's community security backports ([remicollet/php-src-security](https://github.com/remicollet/php-src-security), branch `PHP-7.4-security-backports`) and adds a few FreeBSD ports patches, for building PHP 7.4 by hand on FreeBSD.
>
> | | |
> |---|---|
> | Upstream | [remicollet/php-src-security `PHP-7.4-security-backports`](https://github.com/remicollet/php-src-security/tree/PHP-7.4-security-backports) @ `239d8122851d` |
> | PHP version | 7.4.33 (`phpversion()` unchanged); `php -v` adds `(fork: 20261025-fbsd-239d8122)` |
> | FreeBSD patches | from freebsd-ports `lang/php74` @ `036685c034ba`: applied and not applied, below |
> | Ready-to-build tarball | [freebsd-7.4-latest](https://github.com/azsupport/php-src/releases/tag/freebsd-7.4-latest): `configure` and parsers are pre-generated, no autoconf/bison/re2c needed |
> | Updated | 25.10.2026 (UTC), automatically by [tools/sync.sh](https://github.com/azsupport/php-src/blob/HEAD/tools/sync.sh) |
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
> - `compat-apache-module-name.patch`: make install puts the Apache module into the modules directory of Apache as libphp74.so instead of libphp7.so (every branch of this fork: libphpXY.so), so that the builds of several PHP versions do not overwrite each other. httpd.conf is not changed: the install names the LoadModule line it needs. (azsupport)
> - `compat-c99.patch`: Fix configure test programs that clang 16 and newer (FreeBSD 14/15 base: clang 19) and gcc 14 and newer reject for their implicit int return type, so they failed silently: whether write(2) to stdout works (the CLI then wrote through stdio instead of write(2)), the run check of PHP_CHECK_FUNC_LIB (functions found only in a separate library) and the reentrant time function type. The sources need no change for those compilers. (azsupport; configure results checked against a run with those errors turned into warnings: identical main/php_config.h)
> - `compat-openssl3.patch`: Build and run against OpenSSL 3 (FreeBSD 14/15 base): guard OPENSSL_SSLV23_PADDING (gone in OpenSSL 3), with --with-openssl-legacy-provider (the option of PHP 8.4, off by default) load the legacy provider for RC4 (the default of openssl_seal()), Blowfish, DES, RC2, CAST5 and MD4, and return only the public part from openssl_csr_get_public_key(). No change with OpenSSL 1.1. (azsupport; padding guard and CSR public key extraction as in php-src PHP-8.1 ext/openssl/openssl.c, provider loading per OSSL_PROVIDER_load(3), its configure option as in php-src PHP-8.4 (GH-13951); tested against OpenSSL 3.5.6)
>
> **Bundled PECL extensions** (commit "Bundle PECL extensions"), built only when enabled with their option:
>
> - redis 6.3.0 ([phpredis/phpredis @ `df4fab2de7fc`](https://github.com/phpredis/phpredis/tree/df4fab2de7fc327c54c94a13af2b9542e4fbd720)): `--enable-redis`
> - memcached 3.4.0 ([php-memcached-dev/php-memcached @ `ce37962769fc`](https://github.com/php-memcached-dev/php-memcached/tree/ce37962769fc7b25f9905c4b23fa53df92447a32)): `--enable-memcached --with-libmemcached-dir=/usr/local --disable-memcached-sasl` (package `libmemcached`)
> - memcache 4.0.5.3 ([websupport-sk/pecl-memcache @ `7032b5b5e537`](https://github.com/websupport-sk/pecl-memcache/tree/7032b5b5e53788d077bde04fcf90a8ee46eb30de)): `--enable-memcache`; patch `memcache-4.0.5.3.patch`: Build inside php-src as ext/memcache (bundled by this fork), not only with phpize: config9.m4 looked for its php7/ sources under abs_srcdir, which is the PHP tree there, and its PHP version test could not find php_version.h, so configure stopped ("checking PHP version... unknown"); main/internal_functions.c needs ext/memcache/php_memcache.h for phpext_memcache_ptr. config9.m4 now uses PHP_EXT_SRCDIR(memcache), the extension directory in both cases, adds main/ for the version test, and a top-level php_memcache.h includes php7/php_memcache.h.
> - imagick 3.8.1 ([Imagick/imagick @ `70087bab33ea`](https://github.com/Imagick/imagick/tree/70087bab33eab913e99ac77d64d04d1a2fd0b7b0)): `--with-imagick=/usr/local` (package `ImageMagick7` or `ImageMagick7-nox11`; not together with gmagick); patch `imagick-3.8.1.patch`: Build inside php-src as ext/imagick (bundled by this fork): buildconf runs in the top of the PHP tree, where m4_include of imagemagick.m4 finds no file, so config.m4 now includes ext/imagick/imagemagick.m4; and set the version that PECL packaging fills in ("@PACKAGE_VERSION@" in the git sources) to 3.8.1, for phpversion('imagick').
> - gmagick 2.0.6RC1 ([vitoc/gmagick @ `2936e731e964`](https://github.com/vitoc/gmagick/tree/2936e731e964719d84995a1e64722de5c5c0ee48)): `--with-gmagick=/usr/local` (package `GraphicsMagick`; not together with imagick); patch `gmagick-2.0.6RC1.patch`: Build inside php-src as ext/gmagick (bundled by this fork): configure stops when --with-imagick is given too. GraphicsMagick and ImageMagick have the same MagickWand function names, so built into one PHP, gmagick and imagick would call each other's library.
> - igbinary 3.2.16 ([igbinary/igbinary @ `8326f6a69ebb`](https://github.com/igbinary/igbinary/tree/8326f6a69ebb30dd6258dd536eb0914454fbf146)): `--enable-igbinary`; the igbinary serializer of redis and memcached: `--enable-redis-igbinary`, `--enable-memcached-igbinary`
> - swoole 4.8.13 ([swoole/swoole-src @ `48c8a40b5059`](https://github.com/swoole/swoole-src/tree/48c8a40b5059d4793b31b7646f8e2b1483af14b2)): `--enable-swoole` (OpenSSL when PHP is built `--with-openssl`; brotli compression with the package `brotli`); patch `swoole-4.8.13.patch`: Build inside php-src as ext/swoole (bundled by this fork): the default of --enable-swoole was "yes", which built it into every PHP configured without --disable-all; it is now "no"; drop the option --enable-openssl, which reset PHP_OPENSSL of --with-openssl to "no" so that mysqlnd built without its OpenSSL code (swoole now uses OpenSSL when PHP is built --with-openssl, as swoole 6.2 does); drop the -std=c++11 that config.m4 appends to CXXFLAGS, which inside php-src applies to every C++ file and overrides the C++17 that ext/intl needs with ICU 75 and newer; and the two C++ header checks of configure (valgrind, boost stacktrace) use AC_LANG_PUSH/POP instead of AC_LANG([C++]), which left configure in C++ for every extension after it: their checks ran as C++, and for example readline was not found.
> - openswoole 4.12.1 ([openswoole/ext-openswoole @ `b4a458b59e18`](https://github.com/openswoole/ext-openswoole/tree/b4a458b59e1805fd2201b331225ecbce85954dc6)): `--enable-openswoole` (OpenSSL when PHP is built `--with-openssl`; not together with swoole); patch `openswoole-4.12.1.patch`: Build inside php-src as ext/openswoole (bundled by this fork), on PHP 7.4 to 8.4. configure built OpenSwoole into every PHP, as it tested PHP_SWOOLE (left over from swoole, unset there) instead of PHP_OPENSWOOLE, and the default of --enable-openswoole was "yes"; now only --enable-openswoole builds it, and configure stops when --enable-swoole is given too (same C++ symbols). Drop the option --enable-openssl, which reset PHP_OPENSSL of --with-openssl to "no" so that mysqlnd built without its OpenSSL code (OpenSwoole now uses OpenSSL when PHP is built --with-openssl, as swoole 6.2 does); drop the -std=c++11 that config.m4 appends to CXXFLAGS, which inside php-src applies to every C++ file and overrides the C++17 that ext/intl needs with ICU 75 and newer; include <stdint.h> in swoole_proxy.h (uint8_t unknown with clang 19). For PHP 8.3 and 8.4, which OpenSwoole 4.12 does not support upstream (OpenSwoole 22 and newer changed the API): the new php_url_encode_hash_ex() of 8.3; zend_str_tolower() for php_strtolower(), gone in 8.4; the C stack bounds that PHP 8.3 checks (EG(stack_base), EG(stack_limit)) follow the coroutine stacks, as in swoole 5.1 and newer, so calls inside coroutines no longer fail with "Maximum call stack size reached"; as 8.4 made exit a function (no ZEND_EXIT opcode), the function exit() is wrapped the way the opcode was, so exit in a coroutine or a server still throws Swoole\ExitException; and the embedded PHP library declares its nullable parameters explicitly (?int, ?array), which PHP 8.4 asks for with a deprecation notice at every start; and the two C++ header checks of configure (valgrind, boost stacktrace) use AC_LANG_PUSH/POP instead of AC_LANG([C++]), which left configure in C++ for every extension after it: their checks ran as C++, and for example readline was not found. On FreeBSD, thirdparty/hiredis/fmacros.h no longer defines _XOPEN_SOURCE and _POSIX_C_SOURCE: they hide the BSD types (u_int32_t) that <netinet/ip6.h> needs, which hiredis/net.c includes through swoole_socket.h, and the build stopped there. And include/swoole_socket.h includes <sys/types.h> first: on FreeBSD the socket headers do not include it, and <netinet/ip6.h> needs its u_int32_t, u_int16_t and u_int8_t.
> - excimer 1.2.7 ([wikimedia/excimer @ `23f541b9d970`](https://github.com/wikimedia/excimer/tree/23f541b9d970db0524a1b2506b4df727e5e59998)): `--enable-excimer`; patch `excimer-1.2.7.patch`: Build inside php-src as ext/excimer (bundled by this fork) and on FreeBSD: pass -fvisibility=hidden for the excimer sources only (config.m4 added it to CFLAGS, which inside php-src is that of the whole build); on FreeBSD take the thread id for SIGEV_THREAD_ID from pthread_getthreadid_np(), as FreeBSD has neither gettid() nor SYS_gettid, so the timer backend of 1.2.4 and later did not compile there (the FreeBSD port devel/pecl-excimer stays at 1.2.3).
> - mcrypt 1.0.9 ([php/pecl-encryption-mcrypt @ `ee7378051c17`](https://github.com/php/pecl-encryption-mcrypt/tree/ee7378051c1776414ee6a459d16942e3f9acdbfc)): `--with-mcrypt=/usr/local` (package `libmcrypt`)
>
> **Bundled curl** (commit "Bundle curl"), used only with `--with-curl=bundled`:
>
> - curl 8.23.0 ([release tarball](https://github.com/curl/curl/releases/download/curl-8_23_0/curl-8.23.0.tar.xz), SHA-256 `8dadd7d2536a314f`, the same as in freebsd-ports `ftp/curl`) in `ext/curl/libcurl`; patch `curl-8.23.0.patch` (freebsd-ports): FreeBSD ports patch of the curl configure: accept -D in CFLAGS and -l in LDFLAGS, keep the -O flags of CFLAGS (PR 150854, 177401, 180944), and the libraries it needs in `ext/curl/deps`: c-ares 1.34.9, nghttp2 1.70.0, brotli 1.2.1, zstd 1.5.7, libidn2 2.3.8, libpsl 0.23.3, with the public suffix list of 21.09.2026 (the release files of freebsd-ports, [`freebsd/curl-deps.conf`](https://github.com/azsupport/php-src/blob/HEAD/freebsd/curl-deps.conf)). `--with-curl=bundled` builds all of it into PHP, static, with the OpenSSL of the build (3.0 or later, so not FreeBSD 13.x base): no package needed. c-ares resolves names (a lookup that runs into the timeout ends at once); left out: IMAP, POP3, SMTP, WebSocket, NTLM, DICT, Gopher, IPFS, MQTT, RTSP, Telnet, TFTP, LDAP, SCP/SFTP, GSSAPI. Plain `--with-curl` still takes the libcurl of the system.
>
> **Bundled PCRE** (commit "Bundle PCRE"):
>
> - PCRE2 10.49 ([release tarball](https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.49/pcre2-10.49.tar.bz2), SHA-256 `53c156e1ba416a20`, the same as in freebsd-ports `devel/pcre2`) in `ext/pcre/pcre2lib` instead of the copy upstream bundles; every function of it is renamed to `php_pcre*` (`main/php_compat.h`), so a PCRE library that another module loads into the same process (the libpcre2 of Apache) stays separate; `tests-7.4.patch`: ext/pcre tests that print messages of the library: the wording of PCRE2 10.37+ ("atomic assertion expected", the offset after the character) as well as the old one, as php-src has them since 8.1 and 8.3. `--with-external-pcre` still takes the library of the system.
>
> **Build options of this fork** (commit "Add the build options of this fork"), off unless given to configure:
>
> - `--enable-opcache-static`: OPcache built into PHP instead of opcache.so, as PHP 8.5 always does: the module registers the zend_extension in its MINIT, and the startup of the zend_extension registers the INI entries after its globals, in the order opcache.so has. No zend_extension line is needed; zend_extension=opcache.so is skipped quietly, also when an old opcache.so is still in extension_dir. Without the option opcache.so is built as before.
> - `--disable-extension-loading`: PHP loads no extensions at run time: extension= and zend_extension= lines, dl() and php -z are refused with a warning that names the file, a line for an extension that is built in (extension=mysqli) is skipped quietly, phpinfo() shows "Dynamic Library Support: disabled", and configure stops when an extension would be built as .so (OPcache: --enable-opcache-static). Without the option nothing changes.
>
> The upstream `.github/` CI configuration is removed so that php-src CI does not
> run in this fork. Provided as is, without warranty, by [aZsupport.com](https://azsupport.com).

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
