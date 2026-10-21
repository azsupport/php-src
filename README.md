<!-- freebsd-notes:start -->
> [!IMPORTANT]
> **This is `azsupport/php-src`, branch `freebsd/5.6`: not an official PHP release.**
>
> PHP 5.6 is end-of-life upstream. This branch follows Remi Collet's community security backports ([remicollet/php-src-security](https://github.com/remicollet/php-src-security), branch `PHP-5.6-security-backports-openssl11`) and adds a few FreeBSD ports patches, for building PHP 5.6 by hand on FreeBSD.
>
> | | |
> |---|---|
> | Upstream | [remicollet/php-src-security `PHP-5.6-security-backports-openssl11`](https://github.com/remicollet/php-src-security/tree/PHP-5.6-security-backports-openssl11) @ `5c2cc46b45cf` |
> | PHP version | 5.6.40 (`phpversion()` unchanged); `php -v` adds `(fork: 20261021-fbsd-5c2cc46b)` |
> | FreeBSD patches | from freebsd-ports `lang/php56` @ `d2c06ef5efae`: applied and not applied, below |
> | Ready-to-build tarball | [freebsd-5.6-latest](https://github.com/azsupport/php-src/releases/tag/freebsd-5.6-latest): `configure` and parsers are pre-generated, no autoconf/bison/re2c needed |
> | Updated | 21.10.2026 (UTC), automatically by [tools/sync.sh](https://github.com/azsupport/php-src/blob/HEAD/tools/sync.sh) |
>
> **FreeBSD ports patches** from freebsd-ports [`lang/php56` @ `d2c06ef5efae`](https://github.com/freebsd/freebsd-ports/tree/d2c06ef5efae/lang/php56/files):
>
> **Applied** (commit "Apply curated FreeBSD ports patches"):
>
> - `patch-Makefile.global` (`Makefile.global`): 'make install' does not fail when no php.ini is present.
> - `patch-Zend__zend.h` (`Zend/zend.h`): Do not use alloca() in thread-safe (ZTS) builds on FreeBSD; no effect on non-ZTS builds.
> - `patch-Zend_zend__compile.h` (`Zend/zend_compile.h`): Drop the EX_TMP_VAR pointer-arithmetic macros (replaced in zend_execute.h); avoids undefined behaviour that newer clang miscompiles.
> - `patch-Zend_zend__execute.h` (`Zend/zend_execute.h`): EX_TMP_VAR/EX_TMP_VAR_NUM as inline functions using integer arithmetic (pairs with zend_compile.h).
> - `patch-Zend_zend_list.c` (`Zend/zend_list.c`): Resource list ids are ulong, matching the hash table key type on 64-bit.
> - `patch-Zend_zend_list.h` (`Zend/zend_list.h`): Resource list API prototypes use ulong ids (pairs with zend_list.c).
> - `patch-sapi_apache2handler_config.m4` (`sapi/apache2handler/config.m4`): 'make install' installs the module without editing httpd.conf (no apxs -a).
> - `patch-sapi_fpm_config.m4` (`sapi/fpm/config.m4`): Report the listen queue via SO_LISTENQLEN; FreeBSD's struct tcp_info lacks the Linux fields.
>
> **Not applied:**
>
> - `patch-TSRM_threads.m4`: makes the configure pthreads test pass without creating a thread; no effect on FreeBSD, where the upstream test passes
> - `patch-acinclude.m4`: ports split packaging (core and every extension built as separate packages); not needed when extensions are built into PHP
> - `patch-configure.in`: ports build layout: makes php_config.h include ext/php_config.h, which only the port's Makefile creates (a hand build fails without it), drops the "Nothing to build" and pthreads checks and sets the ports' PEAR include_path
> - `patch-ext_standard_image.c`: ports split packaging (zlib as a separate package); with zlib built in (`--with-zlib`), getimagesize() already supports SWC upstream
> - `patch-ext_zlib_config0.m4`: ports split packaging (`--with-zlib-dir` alone must not enable the zlib extension in the core package)
> - `patch-sapi_apache2filter_config.m4`: the experimental apache2filter SAPI is not used; apache2handler gets the same change
> - `php-fpm.in`: the rc.d script of the port, not a source patch; your own rc.d scripts stay in use
>
> **Build compatibility patches by azsupport** (commit "Apply build compatibility patches"):
>
> - `compat-bison3.patch`: Generate the 5.6 parsers with bison 3.6 and newer (the release tarballs use bison 3.8) like the official 5.6.40 tarball: keep the detailed parse errors ("syntax error, unexpected '{', expecting '('"), because these bison versions ignore the YYERROR_VERBOSE macro of the 5.6 grammars and report only "syntax error" for scripts and INI files, and keep the official token numbers (T_VARIABLE 312, T_OPEN_TAG 376 and so on), because they number T_POW and T_POW_EQUAL by their %token line, which moved most T_* values by 1 or 2. The freebsd/5.6 tarballs made before this patch had both differences. (azsupport; %define parse.error verbose, as in the php-src PHP-7.0 and later grammars; token numbers checked against ext/tokenizer/tests/bug60097.phpt)
> - `compat-c99.patch`: Build with clang 16 and newer (FreeBSD 14/15 base: clang 19) and gcc 14 and newer, which reject implicit int, implicit function declarations and mismatched function pointer types. Fixes the configure test programs that failed silently and gave wrong results (getaddrinfo, so no IPv6 name resolution; readdir_r and fopencookie types, which then broke the build; pread/pwrite; write(2) to stdout; Zend MM alignment; sprintf/snprintf; crypt; libcurl SSL) and the sources that stopped compiling (mbstring UTF-8-Mobile, fileinfo file_replace(), zip mkstemp(), zlib module globals). (azsupport; configure results checked against a run with those errors turned into warnings: identical main/php_config.h)
> - `compat-freetype-pkgconfig.patch`: Find FreeType through pkg-config (freetype2.pc) when freetype-config is missing: FreeType 2.9.1 and newer no longer install it, and the FreeBSD freetype2 package ships only freetype2.pc, so --with-freetype-dir failed with "freetype-config not found". Also builds the bundled GD with FreeType in that case, so imagettftext() and imagettfbbox() draw text and return the bounding box. (azsupport; PHP 7.4 switched ext/gd to pkg-config the same way)
> - `compat-libxml2.patch`: Build against libxml2 2.12 and newer (FreeBSD 15.1 package: 2.15): drop ATTRIBUTE_UNUSED, which newer libxml2 headers no longer define, take a const xmlError in the structured error handler (libxml2 2.12) and a const xmlChar name in the DOM hash scanner (libxml2 2.9.8). (azsupport; the same changes as remicollet PHP-7.4-security-backports ext/libxml/libxml.c and ext/dom/dom_iterators.c)
> - `compat-oniguruma.patch`: Build the bundled oniguruma of ext/mbstring when the oniguruma package is installed (7.4 and 8.x need it): the package's oniguruma.h 6.x in /usr/local/include came before the bundled 5.9 headers in the include path, and php_mbregex.c did not compile ("incomplete definition of type 'php_mb_regex_t'"). The bundled headers now go first. (azsupport; found by the FreeBSD 15.1 build test, PHP_ADD_INCLUDE(dir, 1) prepends)
> - `compat-openssl3.patch`: Build and run against OpenSSL 3 (FreeBSD 14/15 base): guard OPENSSL_SSLV23_PADDING (gone in OpenSSL 3), load the legacy provider for RC4 (the default of openssl_seal()), Blowfish, DES, RC2, CAST5 and MD4, let tls:// and STREAM_CRYPTO_METHOD_TLS_* negotiate TLS 1.0 to 1.3 (5.6 limits them to TLS 1.0, which OpenSSL 3 refuses at its default security level, so they could not connect), and return only the public part from openssl_csr_get_public_key() (that one also with OpenSSL 1.1, where 5.6 leaked the private part too). (azsupport; padding guard and CSR public key extraction as in php-src PHP-8.1 ext/openssl/openssl.c, provider loading per OSSL_PROVIDER_load(3); tested against OpenSSL 3.5.6; tls:// range as in php-src PHP-7.2 and later)
>
> **Bundled PECL extensions** (commit "Bundle PECL extensions"), built only when enabled with their option:
>
> - redis 4.3.0 ([phpredis/phpredis @ `c588f0308a4d`](https://github.com/phpredis/phpredis/tree/c588f0308a4d49368a436e660b4a29a0579f802d)): `--enable-redis`; patch `redis-4.3.0.patch`: Declare the dependency on ext/hash: RedisArray calls php_hash_fetch_ops(), so a PHP 5.6 built with --disable-all and without --enable-hash failed to link (undefined reference to php_hash_fetch_ops); configure now says that redis needs hash.
> - memcached 2.2.0 ([php-memcached-dev/php-memcached @ `7ad95cc555ea`](https://github.com/php-memcached-dev/php-memcached/tree/7ad95cc555ea045e6f91852a1ee93c4348587edb)): `--enable-memcached --with-libmemcached-dir=/usr/local --disable-memcached-sasl` (package `libmemcached`)
> - memcache 3.0.8 ([websupport-sk/pecl-memcache @ `ac96c9cc48fe`](https://github.com/websupport-sk/pecl-memcache/tree/ac96c9cc48fefd3f3037d4d8cbf6ddd94d94317c)): `--enable-memcache`; patch `memcache-3.0.8.patch`: Build with clang and gcc 5+, which use C99 inline semantics: the queue, buffer and key helpers were declared plain (non-static) inline, so no external definition was emitted and memcache did not link (undefined reference to mmc_queue_push and others). They are ordinary functions now, as on Windows.
> - imagick 3.8.1 ([Imagick/imagick @ `70087bab33ea`](https://github.com/Imagick/imagick/tree/70087bab33eab913e99ac77d64d04d1a2fd0b7b0)): `--with-imagick=/usr/local` (package `ImageMagick7` or `ImageMagick7-nox11`); patch `imagick-3.8.1.patch`: Build inside php-src as ext/imagick (bundled by this fork): buildconf runs in the top of the PHP tree, where m4_include of imagemagick.m4 finds no file, so config.m4 now includes ext/imagick/imagemagick.m4; and set the version that PECL packaging fills in ("@PACKAGE_VERSION@" in the git sources) to 3.8.1, for phpversion('imagick').
> - igbinary 2.0.8 ([igbinary/igbinary @ `8a432feec0a7`](https://github.com/igbinary/igbinary/tree/8a432feec0a7c39ff043232d2283c006d243a1c6)): `--enable-igbinary`; the igbinary serializer of redis and memcached: `--enable-redis-igbinary`, `--enable-memcached-igbinary`; patch `igbinary-2.0.8.patch`: Take the PHP version from the source tree when built inside php-src: the check read $phpincludedir/main/php_version.h of an installed PHP, found none, took PHP 7 and compiled src/php7 for PHP 5.6 (unknown type name zend_string).
>
> The upstream `.github/` CI configuration is removed so that php-src CI does not
> run in this fork. Provided as is, without warranty.

> [!WARNING]
> **Interim security backports by azsupport** (commit "Backport security fixes"),
> carried only until the upstream branch has its own fix; not reviewed upstream:
>
> - CVE-2026-109618 OOM hardening for PHP 5.6: _exit() the worker instead of longjmp() out of the memory-exhaustion handler (mirrors the hard-OOM _exit of PHP 8.2+). No upstream fix exists for 5.6. (azsupport, modelled on the hard-OOM _exit() of php/php-src 8.2+ (GHSA-w8hw-w9fx-j79w); written against remicollet PHP-5.6-security-backports-openssl11 @ 5c2cc46b45cf, review when that branch gets its own fix)

The original PHP README follows.
<!-- freebsd-notes:end -->

This is a fork of the official PHP repository which receives backport of security fixes from maintained branches.

This branch is PHP version 5.6.40 with security fix and compatibility fix for OpenSSL 1.1.

