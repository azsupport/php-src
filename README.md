<!-- freebsd-notes:start -->
> [!IMPORTANT]
> **This is `azsupport/php-src`, branch `freebsd/8.4`: not an official PHP release.**
>
> Official PHP 8.4.27 release ([php/php-src](https://github.com/php/php-src), tag `php-8.4.27`) plus a few FreeBSD ports patches, for building PHP by hand on FreeBSD.
>
> | | |
> |---|---|
> | Upstream | [php/php-src `php-8.4.27`](https://github.com/php/php-src/tree/php-8.4.27) @ `00d8bae80154` |
> | PHP version | 8.4.27 (`phpversion()` unchanged); `php -v` adds `(fork: 20261026-fbsd-00d8bae8)` |
> | FreeBSD patches | from freebsd-ports `lang/php84` @ `1a235373d266`: applied and not applied, below |
> | Ready-to-build tarball | [freebsd-8.4-latest](https://github.com/azsupport/php-src/releases/tag/freebsd-8.4-latest): `configure` and parsers are pre-generated, no autoconf/bison/re2c needed |
> | Updated | 26.10.2026 (UTC), automatically by [tools/sync.sh](https://github.com/azsupport/php-src/blob/HEAD/tools/sync.sh) |
>
> **FreeBSD ports patches** from freebsd-ports [`lang/php84` @ `1a235373d266`](https://github.com/freebsd/freebsd-ports/tree/1a235373d266/lang/php84/files):
>
> **Applied** (commit "Apply curated FreeBSD ports patches"):
>
> - `patch-TSRM_TSRM.c` (`TSRM/TSRM.c`): Do not use the Linux aarch64 TLS assembly on FreeBSD (no effect on amd64).
> - `patch-build_Makefile.global` (`build/Makefile.global`): 'make test' does not stop when the egrep that copies the loaded php.ini and the scanned .ini files into tmp-php.ini finds nothing (an empty php.ini, a scan directory without .ini files): BSD make runs the recipe with sh -e.
> - `patch-ext_pcre_php__pcre.h` (`ext/pcre/php_pcre.h`): With --with-external-pcre, include the system <pcre2.h> as the port does; no effect with the bundled PCRE.
> - `patch-php.ini-development` (`php.ini-development`): php.ini-development: session.upload_progress.enabled = Off, a temporary mitigation of CVE-2026-115560 (and CVE-2026-109619) until the next PHP release, as the port; existing php.ini files stay as they are.
> - `patch-php.ini-production` (`php.ini-production`): php.ini-production: session.upload_progress.enabled = Off, a temporary mitigation of CVE-2026-115560 (and CVE-2026-109619) until the next PHP release, as the port; existing php.ini files stay as they are.
> - `patch-sapi_apache2handler_config.m4` (`sapi/apache2handler/config.m4`): 'make install' installs the module without editing httpd.conf (no apxs -a).
> - `patch-sapi_fpm_www.conf.in` (`sapi/fpm/www.conf.in`): Document that IPv4-mapped addresses are disabled by default on FreeBSD.
>
> **Not applied:**
>
> - `patch-configure.ac`: ports build layout: makes php_config.h include ext/php_config.h, which only the port's Makefile creates (a hand build fails without it), drops the configure pthreads check and sets the ports' PEAR include_path
> - `patch-ext_hash_xxhash_xxhash.h`: PowerPC VSX (AltiVec) and s390x only; no effect on amd64
> - `libressl-patch-ext_openssl_openssl.c`: only for builds against LibreSSL (the port applies it only then)
> - `php_session.h`: the full source tree has its own ext/session/php_session.h; the port's copy only serves building ext/soap as a separate package without the session sources
> - `php_fpm.in`: the rc.d script of the port, not a source patch; your own rc.d scripts stay in use
>
> **Build compatibility patches by azsupport** (commit "Apply build compatibility patches"):
>
> - `compat-apache-module-name.patch`: make install puts the Apache module into the modules directory of Apache as libphp84.so instead of libphp.so (every branch of this fork: libphpXY.so), so that the builds of several PHP versions do not overwrite each other. httpd.conf is not changed: the install names the LoadModule line it needs. (azsupport)
>
> **Bundled PECL extensions** (commit "Bundle PECL extensions"), built only when enabled with their option:
>
> - redis 6.3.0 ([phpredis/phpredis @ `df4fab2de7fc`](https://github.com/phpredis/phpredis/tree/df4fab2de7fc327c54c94a13af2b9542e4fbd720)): `--enable-redis`
> - memcached 3.4.0 ([php-memcached-dev/php-memcached @ `ce37962769fc`](https://github.com/php-memcached-dev/php-memcached/tree/ce37962769fc7b25f9905c4b23fa53df92447a32)): `--enable-memcached --with-libmemcached-dir=/usr/local --disable-memcached-sasl` (package `libmemcached`)
> - memcache 8.2 ([websupport-sk/pecl-memcache @ `05db30910e79`](https://github.com/websupport-sk/pecl-memcache/tree/05db30910e791b3841587d18a4e37b4cb6aa04c3)): `--enable-memcache`; patch `memcache-8.2.patch`: Build inside php-src as ext/memcache (bundled by this fork), not only with phpize: config9.m4 looked for its src/ sources under abs_srcdir, which is the PHP tree there, and its PHP version test could not find php_version.h, so configure stopped ("checking PHP version... unknown"); main/internal_functions.c needs ext/memcache/php_memcache.h for phpext_memcache_ptr. config9.m4 now uses PHP_EXT_SRCDIR(memcache), the extension directory in both cases, adds main/ for the version test, and a top-level php_memcache.h includes src/php_memcache.h.
> - imagick 3.8.1 ([Imagick/imagick @ `70087bab33ea`](https://github.com/Imagick/imagick/tree/70087bab33eab913e99ac77d64d04d1a2fd0b7b0)): `--with-imagick=/usr/local` (package `ImageMagick7` or `ImageMagick7-nox11`; not together with gmagick); patch `imagick-3.8.1.patch`: Build inside php-src as ext/imagick (bundled by this fork): buildconf runs in the top of the PHP tree, where m4_include of imagemagick.m4 finds no file, so config.m4 now includes ext/imagick/imagemagick.m4; and set the version that PECL packaging fills in ("@PACKAGE_VERSION@" in the git sources) to 3.8.1, for phpversion('imagick').
> - gmagick 2.0.6RC1 ([vitoc/gmagick @ `2936e731e964`](https://github.com/vitoc/gmagick/tree/2936e731e964719d84995a1e64722de5c5c0ee48)): `--with-gmagick=/usr/local` (package `GraphicsMagick`; not together with imagick); patch `gmagick-2.0.6RC1.patch`: Build inside php-src as ext/gmagick (bundled by this fork): configure stops when --with-imagick is given too. GraphicsMagick and ImageMagick have the same MagickWand function names, so built into one PHP, gmagick and imagick would call each other's library.
> - igbinary 3.2.16 ([igbinary/igbinary @ `8326f6a69ebb`](https://github.com/igbinary/igbinary/tree/8326f6a69ebb30dd6258dd536eb0914454fbf146)): `--enable-igbinary`; the igbinary serializer of redis and memcached: `--enable-redis-igbinary`, `--enable-memcached-igbinary`
> - swoole 6.2.4 ([swoole/swoole-src @ `c7e514509451`](https://github.com/swoole/swoole-src/tree/c7e514509451beafd4d70ce5b78943d51e76381c)): `--enable-swoole` (OpenSSL when PHP is built `--with-openssl`; brotli compression with the package `brotli`); patch `swoole-6.2.4.patch`: Build inside php-src as ext/swoole (bundled by this fork): the default of --enable-swoole was "yes", which built it into every PHP configured without --disable-all; it is now "no"; drop the -std=c++14 that config.m4 appends to CXXFLAGS, which inside php-src applies to every C++ file and overrides the C++17 that ext/intl needs with ICU 75 and newer.
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
> - PCRE2 10.49 ([release tarball](https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.49/pcre2-10.49.tar.bz2), SHA-256 `53c156e1ba416a20`, the same as in freebsd-ports `devel/pcre2`) in `ext/pcre/pcre2lib` instead of the copy upstream bundles; every function of it is renamed to `php_pcre*` (`main/php_compat.h`), so a PCRE library that another module loads into the same process (the libpcre2 of Apache) stays separate. `--with-external-pcre` still takes the library of the system.
>
> **Build options of this fork** (commit "Add the build options of this fork"), off unless given to configure:
>
> - `--enable-opcache-static`: OPcache built into PHP instead of opcache.so, as PHP 8.5 always does: the module registers the zend_extension in its MINIT, and the startup of the zend_extension registers the INI entries after its globals, in the order opcache.so has. No zend_extension line is needed; zend_extension=opcache.so is skipped quietly, also when an old opcache.so is still in extension_dir. Without the option opcache.so is built as before. Not with ZTS and the JIT: before PHP 8.5 the JIT reaches thread-local data in a way that works only from opcache.so, so configure stops (add --disable-opcache-jit, or build opcache.so).
> - `--disable-extension-loading`: PHP loads no extensions at run time: extension= and zend_extension= lines, dl() and php -z are refused with a warning that names the file, a line for an extension that is built in (extension=mysqli) is skipped quietly, phpinfo() shows "Dynamic Library Support: disabled", and configure stops when an extension would be built as .so (OPcache: --enable-opcache-static). Without the option nothing changes.
>
> The upstream `.github/` CI configuration is removed so that php-src CI does not
> run in this fork. Provided as is, without warranty, by [aZsupport.com](https://azsupport.com).

The original PHP README follows.
<!-- freebsd-notes:end -->

<div align="center">
    <a href="https://www.php.net">
        <img
            alt="PHP"
            src="https://www.php.net/images/logos/new-php-logo.svg"
            width="150">
    </a>
</div>

# The PHP Interpreter

PHP is a popular general-purpose scripting language that is especially suited to
web development. Fast, flexible and pragmatic, PHP powers everything from your
blog to the most popular websites in the world. PHP is distributed under the
[PHP License v3.01](LICENSE).

[![Push](https://github.com/php/php-src/actions/workflows/push.yml/badge.svg)](https://github.com/php/php-src/actions/workflows/push.yml)
[![Fuzzing Status](https://oss-fuzz-build-logs.storage.googleapis.com/badges/php.svg)](https://bugs.chromium.org/p/oss-fuzz/issues/list?sort=-opened&can=1&q=proj:php)

## Documentation

The PHP manual is available at [php.net/docs](https://www.php.net/docs).

## Installation

### Prebuilt packages and binaries

Prebuilt packages and binaries can be used to get up and running fast with PHP.

For Windows, the PHP binaries can be obtained from
[windows.php.net](https://windows.php.net). After extracting the archive the
`*.exe` files are ready to use.

For other systems, see the [installation chapter](https://www.php.net/install).

### Building PHP source code

*For Windows, see [Build your own PHP on Windows](https://wiki.php.net/internals/windows/stepbystepbuild_sdk_2).*

For a minimal PHP build from Git, you will need autoconf, bison, and re2c. For
a default build, you will additionally need libxml2 and libsqlite3.

On Ubuntu, you can install these using:

    sudo apt install -y pkg-config build-essential autoconf bison re2c \
                        libxml2-dev libsqlite3-dev

On Fedora, you can install these using:

    sudo dnf install re2c bison autoconf make libtool ccache libxml2-devel sqlite-devel

Generate configure:

    ./buildconf

Configure your build. `--enable-debug` is recommended for development, see
`./configure --help` for a full list of options.

    # For development
    ./configure --enable-debug
    # For production
    ./configure

Build PHP. To speed up the build, specify the maximum number of jobs using `-j`:

    make -j4

The number of jobs should usually match the number of available cores, which
can be determined using `nproc`.

## Testing PHP source code

PHP ships with an extensive test suite, the command `make test` is used after
successful compilation of the sources to run this test suite.

It is possible to run tests using multiple cores by setting `-jN` in
`TEST_PHP_ARGS`:

    make TEST_PHP_ARGS=-j4 test

Shall run `make test` with a maximum of 4 concurrent jobs: Generally the maximum
number of jobs should not exceed the number of cores available.

The [qa.php.net](https://qa.php.net) site provides more detailed info about
testing and quality assurance.

## Installing PHP built from source

After a successful build (and test), PHP may be installed with:

    make install

Depending on your permissions and prefix, `make install` may need super user
permissions.

## PHP extensions

Extensions provide additional functionality on top of PHP. PHP consists of many
essential bundled extensions. Additional extensions can be found in the PHP
Extension Community Library - [PECL](https://pecl.php.net).

## Contributing

The PHP source code is located in the Git repository at
[github.com/php/php-src](https://github.com/php/php-src). Contributions are most
welcome by forking the repository and sending a pull request.

Discussions are done on GitHub, but depending on the topic can also be relayed
to the official PHP developer mailing list internals@lists.php.net.

New features require an RFC and must be accepted by the developers. See
[Request for comments - RFC](https://wiki.php.net/rfc) and
[Voting on PHP features](https://wiki.php.net/rfc/voting) for more information
on the process.

Bug fixes don't require an RFC. If the bug has a GitHub issue, reference it in
the commit message using `GH-NNNNNN`. Use `#NNNNNN` for tickets in the old
[bugs.php.net](https://bugs.php.net) bug tracker.

    Fix GH-7815: php_uname doesn't recognise latest Windows versions
    Fix #55371: get_magic_quotes_gpc() throws deprecation warning

See [Git workflow](https://wiki.php.net/vcs/gitworkflow) for details on how pull
requests are merged.

### Guidelines for contributors

See further documents in the repository for more information on how to
contribute:

- [Contributing to PHP](/CONTRIBUTING.md)
- [PHP coding standards](/CODING_STANDARDS.md)
- [Internal documentation](https://php.github.io/php-src/)
- [Mailing list rules](/docs/mailinglist-rules.md)
- [PHP release process](/docs/release-process.md)

## Credits

For the list of people who've put work into PHP, please see the
[PHP credits page](https://www.php.net/credits.php).
