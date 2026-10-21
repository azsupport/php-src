<!-- freebsd-notes:start -->
> [!IMPORTANT]
> **This is `azsupport/php-src`, branch `freebsd/8.2`: not an official PHP release.**
>
> Official PHP 8.2.35 release ([php/php-src](https://github.com/php/php-src), tag `php-8.2.35`) plus a few FreeBSD ports patches, for building PHP by hand on FreeBSD.
>
> | | |
> |---|---|
> | Upstream | [php/php-src `php-8.2.35`](https://github.com/php/php-src/tree/php-8.2.35) @ `09a9f29a0402` |
> | PHP version | 8.2.35 (`phpversion()` unchanged); `php -v` adds `(fork: 20261021-fbsd-09a9f29a)` |
> | FreeBSD patches | from freebsd-ports `lang/php82` @ `fac6f252ac69`: applied and not applied, below |
> | Ready-to-build tarball | [freebsd-8.2-latest](https://github.com/azsupport/php-src/releases/tag/freebsd-8.2-latest): `configure` and parsers are pre-generated, no autoconf/bison/re2c needed |
> | Updated | 21.10.2026 (UTC), automatically by [tools/sync.sh](https://github.com/azsupport/php-src/blob/HEAD/tools/sync.sh) |
>
> **FreeBSD ports patches** from freebsd-ports [`lang/php82` @ `fac6f252ac69`](https://github.com/freebsd/freebsd-ports/tree/fac6f252ac69/lang/php82/files):
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
> - `patch-ext_mysqli_mysqli__api.c`, `patch-ext_mysqli_mysqli__nonapi.c`, `patch-ext_mysqli_mysqli__prop.c`: ports split packaging of ext/mysqli (built alone with phpize, where the ext/mysqlnd headers are missing); not needed when building from the full source tree
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
> - swoole 6.2.3 ([swoole/swoole-src @ `8b20cd39f8c1`](https://github.com/swoole/swoole-src/tree/8b20cd39f8c19da7aaf70290037e04f616db5ff7)): `--enable-swoole` (OpenSSL when PHP is built `--with-openssl`; brotli compression with the package `brotli`); patch `swoole-6.2.3.patch`: Build inside php-src as ext/swoole (bundled by this fork): the default of --enable-swoole was "yes", which built it into every PHP configured without --disable-all; it is now "no"; drop the -std=c++14 that config.m4 appends to CXXFLAGS, which inside php-src applies to every C++ file and overrides the C++17 that ext/intl needs with ICU 75 and newer.
>
> The upstream `.github/` CI configuration is removed so that php-src CI does not
> run in this fork. Provided as is, without warranty.

The original PHP README follows.
<!-- freebsd-notes:end -->

<div align="center">
    <a href="https://php.net">
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
[![Build status](https://travis-ci.com/php/php-src.svg?branch=master)](https://travis-ci.com/github/php/php-src)
[![Build Status](https://dev.azure.com/phpazuredevops/php/_apis/build/status/php.php-src?branchName=master)](https://dev.azure.com/phpazuredevops/php/_build/latest?definitionId=1&branchName=master)
[![Fuzzing Status](https://oss-fuzz-build-logs.storage.googleapis.com/badges/php.svg)](https://bugs.chromium.org/p/oss-fuzz/issues/list?sort=-opened&can=1&q=proj:php)

## Documentation

The PHP manual is available at [php.net/docs](https://php.net/docs).

## Installation

### Prebuilt packages and binaries

Prebuilt packages and binaries can be used to get up and running fast with PHP.

For Windows, the PHP binaries can be obtained from
[windows.php.net](https://windows.php.net). After extracting the archive the
`*.exe` files are ready to use.

For other systems, see the [installation chapter](https://php.net/install).

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
- [Mailing list rules](/docs/mailinglist-rules.md)
- [PHP release process](/docs/release-process.md)

## Credits

For the list of people who've put work into PHP, please see the
[PHP credits page](https://php.net/credits.php).
