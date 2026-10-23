# PHP for FreeBSD: security-maintained source branches

Ready-to-build PHP sources for FreeBSD (amd64) servers that build PHP by hand
instead of using ports or packages. Each `freebsd/<version>` branch follows an
upstream source of security fixes and adds a small, curated set of FreeBSD ports
patches. Every update is also published as a release tarball with `configure`
and the bison/re2c parsers pre-generated, so a server needs only a C compiler and
`make`, exactly like with the tarballs from php.net.

Not affiliated with the PHP Group, Remi Collet or the FreeBSD Project.
Provided as is, without warranty.

## Branches

| Branch | PHP | Upstream | Upstream support | Latest tarball |
|---|---|---|---|---|
| [`freebsd/8.4`](https://github.com/azsupport/php-src/tree/freebsd/8.4) | 8.4.x | newest official release tag `php-8.4.N` ([php/php-src](https://github.com/php/php-src)) | security fixes until 31.12.2028 | [freebsd-8.4-latest](https://github.com/azsupport/php-src/releases/tag/freebsd-8.4-latest) |
| [`freebsd/8.3`](https://github.com/azsupport/php-src/tree/freebsd/8.3) | 8.3.x | newest official release tag `php-8.3.N` | security fixes until 31.12.2027 | [freebsd-8.3-latest](https://github.com/azsupport/php-src/releases/tag/freebsd-8.3-latest) |
| [`freebsd/8.2`](https://github.com/azsupport/php-src/tree/freebsd/8.2) | 8.2.x | newest official release tag `php-8.2.N` | security fixes until 31.12.2026 | [freebsd-8.2-latest](https://github.com/azsupport/php-src/releases/tag/freebsd-8.2-latest) |
| [`freebsd/8.1`](https://github.com/azsupport/php-src/tree/freebsd/8.1) | 8.1.34 + backports | Remi Collet, [`PHP-8.1-security-backports`](https://github.com/remicollet/php-src-security/tree/PHP-8.1-security-backports) | end of life 31.12.2025 | [freebsd-8.1-latest](https://github.com/azsupport/php-src/releases/tag/freebsd-8.1-latest) |
| [`freebsd/7.4`](https://github.com/azsupport/php-src/tree/freebsd/7.4) | 7.4.33 + backports | Remi Collet, [`PHP-7.4-security-backports`](https://github.com/remicollet/php-src-security/tree/PHP-7.4-security-backports) | end of life 28.11.2022 | [freebsd-7.4-latest](https://github.com/azsupport/php-src/releases/tag/freebsd-7.4-latest) |
| [`freebsd/5.6`](https://github.com/azsupport/php-src/tree/freebsd/5.6) | 5.6.40 + backports | Remi Collet, [`PHP-5.6-security-backports-openssl11`](https://github.com/remicollet/php-src-security/tree/PHP-5.6-security-backports-openssl11) (OpenSSL 1.1 support; OpenSSL 3 through a compat patch here) | end of life 31.12.2018 | [freebsd-5.6-latest](https://github.com/azsupport/php-src/releases/tag/freebsd-5.6-latest) |

For the PHP security release of 21.10.2026 (CVE-2026-109618, CVE-2026-109619,
[announcement](https://www.php.net/archive/2026.php)): `freebsd/8.2`, `freebsd/8.3`
and `freebsd/8.4` carry the official fixed releases 8.2.35, 8.3.36 and 8.4.27.
`freebsd/7.4` and `freebsd/8.1` carry the commit "Avoid state corruption via bailout"
(Arnaud Le Blanc) from Remi Collet's branches, the minimal source backport that the
PHP security team provided for 7.4, 8.0 and 8.1. It is smaller than the complete fix
of 8.2+ (for example, it disables session upload progress in the code), so keep the
configuration mitigations from the announcement on these versions. `freebsd/5.6`
carries a port of that same commit to the PHP 5 engine, not reviewed upstream: fatal
errors of the allocator end the worker with `_exit()` instead of a `longjmp()`, the
state an error before the next request can reach is reset, multipart parsing keeps
only the headers it uses, and session upload progress is off in the code. On memory
exhaustion the worker exits at once, as with the official fix: shutdown functions
do not run and buffered output is lost; the error goes to stderr (the php-fpm or
Apache error log). Keep the configuration mitigations there too. The port is in two
parts: [`backport-php2shell-1.patch`](freebsd/patches/5.6/backport-php2shell-1.patch)
is the code proposed to Remi Collet's branch in
[pull request #32](https://github.com/remicollet/php-src-security/pull/32), the same
code as our own port, as it is, so that the sync skips it once his branch has it;
[`backport-php2shell-2-extra.patch`](freebsd/patches/5.6/backport-php2shell-2-extra.patch)
adds what the official fix and the other 5.6 ports known to us (Ondřej Surý's
php5.6 5.6.40-104, patch 0261, and
[vperetti](https://github.com/vperetti/php-cve-2026-109618-109619-backports)'s) have
and that pull request has not: the smallest arrays for `$_GET`, `$_POST`, `$_COOKIE`,
the earlier reset of the exception after the objects are freed, and the reset of the
header callback.

Remi Collet's 5.6 branch has had no update since 02.07.2026, while his 7.4 branch
got the fixes of the PHP releases of July to October 2026. `freebsd/5.6` carries
our ports of them, one patch per area in
[`freebsd/patches/5.6/`](freebsd/patches/5.6) (`backport-*.patch`, the upstream
commits in each `Origin:` line), with their tests:

| Patch | Fixes |
|---|---|
| `backport-gd-gif-lzw.patch` | CVE-2026-9672: GIF LZW decoder of the bundled libgd |
| `backport-pgsql-quotes.patch` | GHSA-7qpv-r5mr-78m4 (CVE-2026-17543): SQL injection through `pg_insert()` and co. (`E'...'` quoting) |
| `backport-phar-tar.patch` | GHSA-vc5h-9ppw-p5f3 (CVE-2026-7260): loops of symbolic links in tar archives; GHSA-j3wh-g957-2m85: tar entry injection |
| `backport-date-period.patch` | double `DatePeriod::__construct()` (leak), arguments not initialized by their constructor |
| `backport-convert-filters.patch` | GHSA-88hq-2827-7pg6: heap over-read in the convert.* stream filters |
| `backport-fpm-allowed-clients.patch` | GHSA-62xp-839h-2637: `listen.allowed_clients` compared 96 of 128 bits of IPv6 addresses |
| `backport-openssl-peer-name.patch` | GHSA-vvx9-73fr-5jjx: no CN fallback with a DNS, URI or SRV name in the certificate; GHSA-xr7j-rvgx-xq5p: over-read in the wildcard match |
| `backport-http-redirects.patch` | GHSA-fpwc-w8rq-cr92: credentials kept on redirects to another origin; GH-11274: 307/308 keep POST |
| `backport-soap.patch` | GHSA-rgrp-mwpx-f6rm: unbounded recursion in ext/soap; GHSA-cj93-vc83-wgqv: chunk sizes of the SOAP HTTP client |
| `backport-filter-encoded.patch` | GHSA-ch8v-r6jh-4vvr: `FILTER_SANITIZE_ENCODED` left 0xFF as it is |
| `backport-mysqlnd-overread.patch` | GHSA-h35g-vwh6-m678 (CVE-2024-8929) and the partial fix of GHSA-r6x9-5r99-36j7: a hostile MySQL server leaking heap bytes through packet over-reads in mysqlnd |

Not ported: GHSA-9f67-6fw4-hpfp (Windows only) and the fixes for an empty and a
1-character `Location` (5.6 is not affected: it does not follow an empty one and
reads it into a fixed buffer). The mysqlnd fix needed the 2024 hardening
(GHSA-h35g-vwh6-m678, CVE-2024-8929) too, which neither Remi Collet's nor Ondřej
Surý's 5.6 has, so `backport-mysqlnd-overread.patch` carries over both the 2024
commit and the 2026 partial fix from PHP 7.4, with the fake-server protocol tests
adapted to 5.6. Of these, TuxCare's alt-php56 5.6.40-135 (errata of 10.08.2026,
for example [CLSA-2026:1786360064](https://errata.tuxcare.com/els_alt_php/el8/CLSA-2026-1786360064.html))
fixes CVE-2026-9672, CVE-2026-17543 and CVE-2026-7260.

Every branch is upstream plus these commits, in this order:

1. **Apply curated FreeBSD ports patches**: taken from `lang/phpXY` in the
   [FreeBSD ports collection](https://github.com/freebsd/freebsd-ports); the patch
   files with a description and origin line are in [`freebsd/patches/`](freebsd/patches).
   The same commit removes the upstream `.github/` directory, so that php-src's own
   CI does not run in this fork (release tarballs never contain it anyway).
2. **Apply build compatibility patches** (5.6 and 7.4): changes that make an old
   branch build and work on current FreeBSD, see
   [Build compatibility patches](#build-compatibility-patches).
3. **Backport security fixes** (only while there is one, now 5.6): see
   [Interim backports](#interim-backports).
4. **Bundle PECL extensions**: redis, memcached, memcache, igbinary, imagick,
   gmagick, swoole, OpenSwoole, excimer and mcrypt in `ext/`, built only when
   enabled, see
   [Bundled PECL extensions](#bundled-pecl-extensions).
5. **Bundle curl**: curl in `ext/curl/libcurl`, built into PHP with
   `--with-curl=bundled`, see [Bundled curl](#bundled-curl).
6. **Bundle PCRE**: the newest PCRE2 (5.6: PCRE 8.45) instead of the one upstream
   bundles, see [Bundled PCRE](#bundled-pcre).
7. **Show the build id in the `php -v` banner**: a new `PHP_FORK_BUILD` macro is
   appended to the banner by C string-literal concatenation, so `php -v` shows the
   build date and upstream commit, for example
   `PHP 7.4.33 (cli) (built: ...) (fork: 20261021-fbsd-802c2107)`. `PHP_VERSION`
   stays the plain upstream `7.4.33`, so `phpversion()`, `version_compare()` and
   `PHP x.y.z` parsers are not disturbed. On 8.2+ the banner is shared by every SAPI
   (`php -v`, `php-fpm -v`); on 5.6/7.4 it is the CLI banner. `phpinfo()` shows the
   plain version, not the build id.
8. **README: describe the freebsd/X.Y branch**: a notes block on top of the original
   README with the exact upstream commit (`Upstream-Commit:` trailer) and the lists
   of applied and not applied ports patches; the release notes carry the same lists.

Remi Collet's branches are mirrored under their original names
(`PHP-5.6-security-backports-openssl11`, `PHP-7.4-security-backports`,
`PHP-8.1-security-backports`) and kept current by the workflow. The release tags
`php-5.6.40`, `php-7.4.33`, `php-8.1.34`, `php-8.2.34`, `php-8.3.35` and
`php-8.4.26` were mirrored once on 21.10.2026; newer official tags are not mirrored,
because pushing them would start php-src's tag-triggered CI here, but their full
history is part of the `freebsd/8.x` branches.

### FreeBSD ports patches: applied and not applied

Only patches that matter for a monolithic build on FreeBSD are applied:

- `sapi/fpm/config.m4` (5.6 to 8.3): FPM reports the listen queue via
  `SO_LISTENQLEN`; FreeBSD's `struct tcp_info` lacks the Linux fields.
- `sapi/apache2handler/config.m4`: `make install` installs the Apache module
  without editing `httpd.conf` (no `apxs -a`), which matters on servers with
  several PHP builds.
- `build/Makefile.global` (`Makefile.global` in 5.6): `make install` does not
  fail when no `php.ini` is present.
- `sapi/fpm/www.conf.in` (7.4+): documents that IPv4-mapped addresses are
  disabled by default on FreeBSD.
- `TSRM/TSRM.c` (8.1+): no Linux aarch64 TLS assembly on FreeBSD (no effect on amd64).
- `ext/pcre/php_pcre.h` (8.4): with `--with-external-pcre`, the system `<pcre2.h>`
  is included as in the port; no effect with the bundled PCRE.
- 5.6 only, `Zend/zend.h`: no `alloca()` in thread-safe (ZTS) builds on FreeBSD;
  no effect on non-ZTS builds.
- 5.6 only, `Zend/zend_compile.h`, `Zend/zend_execute.h`, `Zend/zend_list.[ch]`:
  pointer-arithmetic macros turned into inline functions (avoids undefined
  behaviour that newer clang miscompiles) and 64-bit resource list ids.

Not applied, by kind:

- the ports' split packaging, where every extension is a separate package:
  `configure.ac` / `configure.in` (they include an `ext/php_config.h` that only the
  ports' Makefile creates, so a hand build would fail, and set the ports' PEAR
  `include_path`), `acinclude.m4`, `ext/mysqli/*`, `ext/zlib/config0.m4`,
  `ext/standard/image.c`, `php_session.h`;
- other CPU architectures: PowerPC `sljit` and `xxhash`;
- `ext/openssl/openssl.c` for LibreSSL (8.4);
- 5.6: the experimental apache2filter SAPI and the ports' tweak of the configure
  pthreads check;
- the ports' rc.d scripts (`php-fpm.in`, `php_fpm.in`).

The exact list for each version, one line per port file with the reason, is in
`freebsd/patches/<version>/SKIPPED`, in the branch README and in the release notes.

## Building on FreeBSD from a release tarball

The `freebsd-<version>-latest` release always carries the newest tarball of a
branch; dated releases (`freebsd-<version>-<YYYYMMDD>-<commit>`) are kept. A tarball
unpacks into a directory with the date and the upstream commit, for example
`php-7.4.33-fbsd-20261021-802c2107/`, and the PHP built from it shows the same in the
`php -v` banner: `PHP 7.4.33 (cli) (built: ...) (fork: 20261021-fbsd-802c2107)`. The
version itself stays `7.4.33`. Tarballs published before this was added (21.10.2026)
have no `(fork: ...)` in the banner.

Each block rebuilds one version with the options of the PHP installed in
`/usr/local/phpXY`: it downloads and checks the newest tarball, unpacks it in
`/root`, writes `config.installed.sh` with [`tools/config-check.sh`](tools/config-check.sh),
then configures, builds and installs. Paste a block as it is: the commands work in
both `sh` and `csh` and have no comments on purpose, because an interactive csh
does not treat `#` as a comment. If a PHP lives elsewhere (for example
`/usr/local/php5640`), change the prefix in the `config-check.sh` line and in the
last line. Restart Apache or php-fpm afterwards, so that no worker keeps running
the old binary.

### PHP 8.4

```sh
cd /root
fetch https://github.com/azsupport/php-src/releases/download/freebsd-8.4-latest/php-8.4-fbsd-latest.tar.xz
fetch https://github.com/azsupport/php-src/releases/download/freebsd-8.4-latest/php-8.4-fbsd-latest.tar.xz.sha256
sha256 -c `cut -d' ' -f1 php-8.4-fbsd-latest.tar.xz.sha256` php-8.4-fbsd-latest.tar.xz
tar xf php-8.4-fbsd-latest.tar.xz
cd /root/`tar tf php-8.4-fbsd-latest.tar.xz | head -1`
fetch https://raw.githubusercontent.com/azsupport/php-src/master/tools/config-check.sh
sh config-check.sh /usr/local/php84
sh config.installed.sh
make -j`sysctl -n hw.ncpu`
make install
/usr/local/php84/bin/php -v
```

### PHP 8.3

```sh
cd /root
fetch https://github.com/azsupport/php-src/releases/download/freebsd-8.3-latest/php-8.3-fbsd-latest.tar.xz
fetch https://github.com/azsupport/php-src/releases/download/freebsd-8.3-latest/php-8.3-fbsd-latest.tar.xz.sha256
sha256 -c `cut -d' ' -f1 php-8.3-fbsd-latest.tar.xz.sha256` php-8.3-fbsd-latest.tar.xz
tar xf php-8.3-fbsd-latest.tar.xz
cd /root/`tar tf php-8.3-fbsd-latest.tar.xz | head -1`
fetch https://raw.githubusercontent.com/azsupport/php-src/master/tools/config-check.sh
sh config-check.sh /usr/local/php83
sh config.installed.sh
make -j`sysctl -n hw.ncpu`
make install
/usr/local/php83/bin/php -v
```

### PHP 8.2

```sh
cd /root
fetch https://github.com/azsupport/php-src/releases/download/freebsd-8.2-latest/php-8.2-fbsd-latest.tar.xz
fetch https://github.com/azsupport/php-src/releases/download/freebsd-8.2-latest/php-8.2-fbsd-latest.tar.xz.sha256
sha256 -c `cut -d' ' -f1 php-8.2-fbsd-latest.tar.xz.sha256` php-8.2-fbsd-latest.tar.xz
tar xf php-8.2-fbsd-latest.tar.xz
cd /root/`tar tf php-8.2-fbsd-latest.tar.xz | head -1`
fetch https://raw.githubusercontent.com/azsupport/php-src/master/tools/config-check.sh
sh config-check.sh /usr/local/php82
sh config.installed.sh
make -j`sysctl -n hw.ncpu`
make install
/usr/local/php82/bin/php -v
```

### PHP 8.1

```sh
cd /root
fetch https://github.com/azsupport/php-src/releases/download/freebsd-8.1-latest/php-8.1-fbsd-latest.tar.xz
fetch https://github.com/azsupport/php-src/releases/download/freebsd-8.1-latest/php-8.1-fbsd-latest.tar.xz.sha256
sha256 -c `cut -d' ' -f1 php-8.1-fbsd-latest.tar.xz.sha256` php-8.1-fbsd-latest.tar.xz
tar xf php-8.1-fbsd-latest.tar.xz
cd /root/`tar tf php-8.1-fbsd-latest.tar.xz | head -1`
fetch https://raw.githubusercontent.com/azsupport/php-src/master/tools/config-check.sh
sh config-check.sh /usr/local/php81
sh config.installed.sh
make -j`sysctl -n hw.ncpu`
make install
/usr/local/php81/bin/php -v
```

### PHP 7.4

```sh
cd /root
fetch https://github.com/azsupport/php-src/releases/download/freebsd-7.4-latest/php-7.4-fbsd-latest.tar.xz
fetch https://github.com/azsupport/php-src/releases/download/freebsd-7.4-latest/php-7.4-fbsd-latest.tar.xz.sha256
sha256 -c `cut -d' ' -f1 php-7.4-fbsd-latest.tar.xz.sha256` php-7.4-fbsd-latest.tar.xz
tar xf php-7.4-fbsd-latest.tar.xz
cd /root/`tar tf php-7.4-fbsd-latest.tar.xz | head -1`
fetch https://raw.githubusercontent.com/azsupport/php-src/master/tools/config-check.sh
sh config-check.sh /usr/local/php74
sh config.installed.sh
make -j`sysctl -n hw.ncpu`
make install
/usr/local/php74/bin/php -v
```

### PHP 5.6

```sh
cd /root
fetch https://github.com/azsupport/php-src/releases/download/freebsd-5.6-latest/php-5.6-fbsd-latest.tar.xz
fetch https://github.com/azsupport/php-src/releases/download/freebsd-5.6-latest/php-5.6-fbsd-latest.tar.xz.sha256
sha256 -c `cut -d' ' -f1 php-5.6-fbsd-latest.tar.xz.sha256` php-5.6-fbsd-latest.tar.xz
tar xf php-5.6-fbsd-latest.tar.xz
cd /root/`tar tf php-5.6-fbsd-latest.tar.xz | head -1`
fetch https://raw.githubusercontent.com/azsupport/php-src/master/tools/config-check.sh
sh config-check.sh /usr/local/php56
sh config.installed.sh
make -j`sysctl -n hw.ncpu`
make install
/usr/local/php56/bin/php -v
```

For 5.6 on FreeBSD 14 and 15, `--with-mcrypt=/usr/local` needs the `libmcrypt`
package (`--with-pcre-regex=/usr/local` is left out with the bundled PCRE 8.45, see
[Bundled PCRE](#bundled-pcre)); FreeType is
found through `pkg-config` (the `freetype2` package no longer ships
`freetype-config`).

The argument of `config-check.sh` is the install directory (`/usr/local/php82`);
the script runs `bin/php` from it (or `sbin/php-fpm`, `bin/php-cgi`), and a path to
one of those binaries works too. On a server where PHP comes from packages
(`lang/phpXY`, `phpXY-*`, `mod_phpXY`), use `sh config-check.sh --pkg` instead (or
`--pkg php74` when several PHP versions are installed as packages): it writes
`config.installed.sh` for a hand build in `/usr/local/phpXY` with one option per
installed extension package and the port options of `phpXY`, takes `CFLAGS` and
`CPUTYPE` from `/etc/make.conf`, lists what it does not carry over (PECL packages,
tools) and prints the `pkg set -A 0` line that keeps the libraries when the packages
are removed later. The bundled PECL extensions keep what their packages were built
with, as `php --ri` of the package PHP shows it: lz4 and zstd for redis (on by default
in `databases/php-redis`), SASL, the JSON serializer and `MemcachedServer` for
memcached (the defaults of `databases/pecl-memcached`), igbinary, swoole's hooks. One build makes only one SAPI module (`./configure`: "You can
build only one SAPI module"), and the ports build the Apache module (`mod_phpXY`)
and the embed library (the `EMBED` option of `phpXY`, `libphp7.so` in
`/usr/local/lib`) separately: with `mod_phpXY` installed the script keeps the
Apache module, leaves `--enable-embed` out and says whether a package links against
the embed library (`pkg shlib -R libphp7.so`).

`config-check.sh` takes the options of the installed PHP (`php -n -i`, Configure
Command), never a `config.nice` blindly: a `config.nice` may come from a configure
run that was never installed. It compares them with the `config.nice` of the old
build, which it finds itself: `/root/php-<installed version>/config.nice`, or the
newest `/root/php-<installed version>-fbsd-*/config.nice` from an earlier build of
this fork; another one can be given as the second argument
(`sh config-check.sh /usr/local/php74 /root/php-7.4.33/config.nice`). PHP 5.6
records options with spaces in a broken quoting (`'CFLAGS=-O3 '-pipe' ...''`); the
script reads them as the shell would, as one option. `php-config
--configure-options` (taken when the binary does not run) prints the options
without any quotes, so `CFLAGS=-O3 -pipe ...` comes out as separate words; the
script puts the words after a `NAME=value` back into its value.

The environment is the same for every PHP build, whatever the old build had:

```
CFLAGS='-O3 -pipe -march=<CPUTYPE of /etc/make.conf> -fstack-protector-strong -fno-strict-aliasing'
CXXFLAGS='-O3 -pipe -march=<CPUTYPE of /etc/make.conf> -fstack-protector-strong -fno-strict-aliasing'
LIBS='-lpthread'
```

and no `LDFLAGS` (clang needs no `-fstack-protector` to link; `/usr/local/phpdeps`
adds its own). `CXXFLAGS` gets `-std=c++17` only for intl on PHP 7.4 and later when
`c++` defaults to an older standard: clang 16 and later (FreeBSD 13.3 and later)
default to C++17, and PHP 8.1 and later pick it for ICU 74 and later themselves. The
`CFLAGS`, `CXXFLAGS`, `LDFLAGS`, `LIBS`, `CPPFLAGS`, `CC`, `CXX` and `CPP` lines of
the old `config.nice` and every `NAME=value` option of the installed build (the
environment of its configure run, which autoconf records: PHP 5.6 keeps `CFLAGS`
and the like there, the ports leave `CC=cc`, `CPP=cpp`, `PKG_CONFIG`,
`LDFLAGS=-fstack-protector`) are dropped and listed in the report; the other
environment lines of `config.nice` (`PKG_CONFIG_PATH`, `OPENSSL_CFLAGS`, ...) are
carried over. `--build` names our
build and the system it is built on, in the form of the ports'
`amd64-portbld-freebsd15.1`: `amd64-srcbld-freebsd15.1`; `build_alias` goes.

`-march` always comes from `/etc/make.conf` of the server the script runs on
(`CPUTYPE`, or a `-march=` in its `CFLAGS`; none without either): a `-march` of a
`config.nice` copied from a server with another CPU is not carried over. When the
CPU lacks what the `-march` needs (`x86-64-v4` needs AVX-512, `x86-64-v3` AVX2),
the script warns: PHP built with it would stop with `Illegal instruction` there.

Building straight from a branch also works, but then autoconf, bison and re2c
are required (`./buildconf --force` first).

### Build test on FreeBSD

[`.github/workflows/build-test.yml`](.github/workflows/build-test.yml) builds the
`-latest` tarballs in a FreeBSD VM (default 15.1: clang 19, base OpenSSL 3.5,
libraries from `pkg`) with the configure options of our servers, the bundled curl
(`--with-curl=bundled`) and `--with-openssl-legacy-provider`, then runs `php -v`,
`php -m`, [`tools/build-test-smoke.php`](tools/build-test-smoke.php) (parse errors,
DNS and IPv6, `tls://`, `ssl://` and `https://`, the OpenSSL legacy ciphers,
`openssl_seal()`, GD with FreeType, XML, sessions, the bundled curl and more) and a
part of the PHP test suite. The result shows per version on the run page. Start it
on https://github.com/azsupport/php-src/actions/workflows/build-test.yml with
**Run workflow**. On a FreeBSD machine the same script runs from a checkout of this
branch, with the tarballs in `dist/`: `sh tools/build-test.sh --deps 5.6 7.4`
installs the packages, `sh tools/build-test.sh --tests 5.6 7.4` builds and checks;
the presets are in [`tools/build-test.sh`](tools/build-test.sh).

### Bundled PECL extensions

The branches and tarballs carry these PECL extensions in `ext/`, so they are built
into PHP like the bundled ones and need no `phpize` or `extension=` line. Nothing
changes unless their option is given:

| PHP | redis | memcached | memcache | igbinary | imagick | gmagick |
|---|---|---|---|---|---|---|
| 8.2, 8.3, 8.4 | 6.3.0 | 3.4.0 | 8.2 | 3.2.16 | 3.8.1 | 2.0.6RC1 |
| 8.1 | 6.3.0 | 3.4.0 | 8.2 | 3.2.16 | 3.8.1 | 2.0.6RC1 |
| 7.4 | 6.3.0 | 3.4.0 | 4.0.5.3 | 3.2.16 | 3.8.1 | 2.0.6RC1 |
| 5.6 | 4.3.0 | 2.2.0 | 3.0.8 | 2.0.8 | 3.8.1 | 1.1.7RC3 |

| PHP | swoole | OpenSwoole | excimer | mcrypt |
|---|---|---|---|---|
| 8.2, 8.3, 8.4 | 6.2.3 | 4.12.1 | 1.2.7 | 1.0.9 |
| 8.1 | 6.1.10 | 4.12.1 | 1.2.7 | 1.0.9 |
| 7.4 | 4.8.13 | 4.12.1 | 1.2.7 | 1.0.9 |
| 5.6 | | | | in PHP 5.6 itself |

| Extension | configure option | FreeBSD package |
|---|---|---|
| [redis](https://pecl.php.net/package/redis) | `--enable-redis` | |
| [memcached](https://pecl.php.net/package/memcached) | `--enable-memcached --with-libmemcached-dir=/usr/local --disable-memcached-sasl` | `libmemcached` |
| [memcache](https://pecl.php.net/package/memcache) | `--enable-memcache` | |
| [igbinary](https://pecl.php.net/package/igbinary) | `--enable-igbinary`; for its use as the serializer of redis and memcached also `--enable-redis-igbinary` and `--enable-memcached-igbinary` | |
| [imagick](https://pecl.php.net/package/imagick) | `--with-imagick=/usr/local`; not together with gmagick | `ImageMagick7` or `ImageMagick7-nox11` |
| [gmagick](https://pecl.php.net/package/gmagick) | `--with-gmagick=/usr/local`; not together with imagick | `GraphicsMagick` |
| [swoole](https://pecl.php.net/package/swoole) (7.4 and newer) | `--enable-swoole`; not together with OpenSwoole | `brotli` (optional, for brotli compression) |
| [OpenSwoole](https://pecl.php.net/package/openswoole) (7.4 and newer) | `--enable-openswoole`; not together with swoole | |
| [excimer](https://pecl.php.net/package/excimer) (7.4 and newer) | `--enable-excimer` | |
| [mcrypt](https://pecl.php.net/package/mcrypt) (7.4 and newer) | `--with-mcrypt=/usr/local` | `libmcrypt` |

The versions are the newest stable PECL releases for each PHP version, with these
exceptions:
- memcache for 5.6 is 3.0.8, the release that distributions shipped for PHP 5.5/5.6;
  its only stable 5.x release is 2.2.7 of 2012.
- gmagick has no stable release at all: 2.0.6RC1 (beta, 2021) plus the two later
  commits of its git master with the PHP 8.1 fixes, and 1.1.7RC3 for 5.6.
- OpenSwoole is 4.12.1 everywhere, see below.

The sources come from the upstream git repositories at the commit of the release tag
(gmagick, which has no tags: the commit of the release), pinned in
[`freebsd/pecl.conf`](freebsd/pecl.conf); the fixes that make them build inside
php-src with clang 19 are in [`freebsd/pecl/`](freebsd/pecl). The extensions need
`--enable-session` (session handlers); on 5.6 and 7.4 redis also needs
`--enable-json`, and on 5.6 `--enable-hash`.

Two pairs can be built only one at a time, and configure stops when both options of a
pair are given. GraphicsMagick and ImageMagick have the same MagickWand function
names, so imagick and gmagick built into one PHP would call each other's library;
OpenSwoole is a fork of swoole with the same C++ symbols. To have both of a pair on a
server, build one into PHP and the other as a shared module with `phpize`.

OpenSwoole is 4.12.1 for every version from 7.4 on, the 4.x line the servers run:
OpenSwoole 22 and newer changed the API (namespace `OpenSwoole\`, `openswoole.*` ini
settings, no `Co\` and `swoole.use_shortname`). 4.12 supports PHP up to 8.2 upstream;
for 8.3 and 8.4 the patch ports it: the new `php_url_encode_hash_ex()` of 8.3,
`zend_str_tolower()` for `php_strtolower()` (gone in 8.4), the C stack bounds that PHP
8.3 checks follow the coroutine stacks (otherwise every call in a coroutine fails with
"Maximum call stack size reached"), `exit()` in a coroutine or a server still throws
`Swoole\ExitException` on 8.4 (where exit became a function), and the embedded PHP
library declares its nullable parameters explicitly (PHP 8.4 deprecation notices).
OpenSwoole has no FreeBSD port, and upstream it did not compile on FreeBSD: its
`swoole_socket.h` includes `<netinet/ip6.h>` before `<sys/types.h>`, and its hiredis
sets `_XOPEN_SOURCE`, which hides the BSD types `<netinet/ip6.h>` needs; the patch
fixes both, and the build test builds it with gmagick on 7.4 to 8.4.

Upstream, swoole and OpenSwoole are on by default (`--enable-swoole`,
`--enable-openswoole`), and OpenSwoole's configure tests the variable of swoole
instead of its own: inside php-src that would build them into every PHP (without
`--disable-all`, and OpenSwoole even with it); the patches make them off by default.
For swoole 4.8 and 6.1 and for OpenSwoole the patches also drop the upstream
`--enable-openssl`: inside php-src it reset the `--with-openssl` setting, and mysqlnd
then built without its OpenSSL code (RSA for `caching_sha2_password`); they now use
OpenSSL when PHP is built `--with-openssl`. They drop the `-std=c++11`/`-std=c++14`
that swoole appends to `CXXFLAGS`, which inside php-src would apply to ext/intl too
(ICU 75 and newer need C++17). swoole 6.x calls `sw_usleep()`, declared nowhere, in
the branch that FreeBSD (no futex) compiles: `usleep()` as in the FreeBSD port
`devel/php-swoole`. excimer adds `-fvisibility=hidden` for its own sources only, and on FreeBSD takes
the thread id of its timer thread from `pthread_getthreadid_np()`: FreeBSD has no
`gettid()`, so excimer 1.2.4 and later did not compile there (the port
`devel/pecl-excimer` stays at 1.2.3).

With `--enable-memcached-igbinary`, igbinary becomes the default serializer of
memcached (`memcached.serializer = igbinary`) for arrays and objects. A PHP built
without igbinary cannot read such values, so while servers with and without it
share one memcached, set `memcached.serializer = php` in `php.ini`. Values already
stored with the php serializer stay readable either way. redis serializes nothing
until `Redis::OPT_SERIALIZER` is set, so there igbinary is used only where the code
asks for `Redis::SERIALIZER_IGBINARY`.

To add them to a rebuild, put the options after `sh config.installed.sh`, for example
`sh config.installed.sh --enable-redis --enable-memcache`, and remove the
`extension=redis.so` lines of the old shared modules from `php.ini`.
`config-check.sh` does not add them to `config.installed.sh` on its own: for the
shared modules of the installed PHP that the tree bundles, it ends with the full
command, `sh config.installed.sh` plus their options, ready to copy. The options carry
what the modules were built with (`php --ri`: the igbinary serializer, lzf/zstd/lz4,
SASL, swoole's curl, c-ares, pgsql), plus `--enable-json`, `--enable-hash` or
`--enable-session` when the installed build lacks what they need, and the report
lists the `extension=` lines (file and line) to remove after `make install`. With
`--pkg`, the installed `phpXY-pecl-*` packages are converted like the other extension
packages.

A daily workflow, [`upstream-check.yml`](.github/workflows/upstream-check.yml), looks
for newer releases of these extensions (repository tags and PECL, checked against the
PHP versions each release supports) and for FreeBSD ports commits that change the
patches or the build of their ports and of `lang/php8x`. Each finding opens one issue
labelled `upstream`; nothing is applied on its own. What it follows is listed in
[`freebsd/upstream.conf`](freebsd/upstream.conf).

### OpenSSL

- 8.1 and newer support OpenSSL 3 upstream: build against the base system
  OpenSSL (`--with-openssl`).
- 7.4 builds against the OpenSSL 3 of the base system of FreeBSD 14 and 15
  (3.5.6 on FreeBSD 15.1) thanks to
  [`compat-openssl3.patch`](freebsd/patches/7.4/compat-openssl3.patch):
  `--with-openssl` is enough, as FreeBSD ships `openssl.pc`. RC4 (the default of
  `openssl_seal()`), Blowfish, DES, RC2, CAST5 and MD4 need
  `--with-openssl-legacy-provider` there (below). What behaves differently from
  OpenSSL 1.1 is OpenSSL 3 itself, the same as with PHP 8.x: TLS 1.0/1.1 are off by default, RSA PKCS#1 v1.5 decryption with a wrong key
  returns random bytes instead of failing (protection against the Marvin
  attack), DSA/DH keys below 512 bits and certificates with malformed times are
  refused. A 7.4 build against a separate OpenSSL 1.1 behaves as before.
- 5.6 builds against the same OpenSSL 3 of the base system with
  [`compat-openssl3.patch`](freebsd/patches/5.6/compat-openssl3.patch)
  (`--with-openssl=/usr`), with the same `--with-openssl-legacy-provider` and the
  same OpenSSL 3 differences as 7.4. On top of that, `tls://` and
  `STREAM_CRYPTO_METHOD_TLS_*` negotiate TLS 1.0 to 1.3: 5.6 limits them to TLS
  1.0, which OpenSSL 3 refuses at its default security level, so they could not
  connect at all (`ssl://`, `https://` and `STREAM_CRYPTO_METHOD_SSLv23_*` already
  negotiated the newest version). A 5.6 build against a separate OpenSSL 1.1
  behaves as before.

`--with-openssl-legacy-provider` loads the OpenSSL 3 legacy provider together with
the default one at startup, so RC4, Blowfish, DES, RC2, CAST5, MD4 and the like work
without editing `openssl.cnf`. PHP 8.4 has the option upstream
([php-src GH-13951](https://github.com/php/php-src/pull/13951)); this fork adds the
same option to 5.6, 7.4, 8.1, 8.2 and 8.3. It is off by default, as upstream. The
module is `/usr/lib/ossl-modules/legacy.so`, part of the base system of FreeBSD 14
and 15; if it is missing, PHP starts and those algorithms stay unavailable. With
OpenSSL 1.1 (FreeBSD 13.x base) the option changes nothing, as the algorithms are
built in there. `config-check.sh` adds it to a build against OpenSSL 3 when the
installed PHP can do RC4 (built against OpenSSL 1.1, or with the legacy provider),
so that data encrypted with `openssl_encrypt(..., "rc4", ...)` on the old build stays
readable, and always for 5.6 and 7.4, whose `openssl_seal()` uses RC4 by default.
`sh config.installed.sh --without-openssl-legacy-provider` leaves it out.

### Bundled curl

Every branch carries curl 8.23.0 in `ext/curl/libcurl`: the release tarball (its
SHA-256 is the one in freebsd-ports `ftp/curl`) with the configure patch of that
port. `--with-curl=bundled` builds it during `configure` (a minute or two, log in
`ext/curl/libcurl-build.log`) and links it into PHP, static, against the OpenSSL
that PHP itself takes, with the options of the FreeBSD port except DICT, Gopher,
IPFS, MQTT, RTSP, Telnet, TFTP, LDAP, SCP/SFTP (libssh2) and GSSAPI. PHP then does
not depend on the curl package, and its curl is as new as the tarball. It needs the
packages `libnghttp2`, `brotli`, `zstd`, `libidn2` and `libpsl`, which the curl
package pulls in anyway. Its symbols are not exported from `php` and `libphp.so`,
so a module that loads the libcurl of the system does not mix with it. Plain
`--with-curl` still takes the system libcurl.

curl 8.18.0 and later need OpenSSL 3.0 or later. FreeBSD 13.x has OpenSSL 1.1.1 in
its base system, so there `config-check.sh` keeps `--with-curl` (the curl package)
and says why; on FreeBSD 14 and 15 it writes `--with-curl=bundled` and lists the
packages that are missing. A curl security fix reaches PHP with a rebuild: the daily
upstream check opens an issue for each new curl release and for changes of the port.

### Bundled PCRE

php-src bundles an old PCRE: 5.6 has PCRE 8.38, 7.4 PCRE2 10.35, 8.1 10.39, 8.2 10.40,
8.3 10.42, 8.4 10.44 (php-src master too, October 2026). Those copies have known
memory safety bugs: out-of-bounds reads in the JIT compiler before 10.40
([CVE-2022-1586](https://osv.dev/vulnerability/CVE-2022-1586),
[CVE-2022-1587](https://osv.dev/vulnerability/CVE-2022-1587): 7.4 and 8.1), the
fixes of 10.48 (out-of-bounds reads and writes, among them in `pcre2_match` after a
JIT fallback on invalid UTF,
[CVE-2026-89156](https://security-tracker.debian.org/tracker/CVE-2026-89156);
[oss-security, 04.09.2026](https://openwall.com/lists/oss-security/2026/09/04/7))
and an out-of-bounds write of the JIT with an attacker-controlled pattern before
10.49 ([CVE-2026-103111](https://app.opencve.io/cve/CVE-2026-103111)), which hit every
branch; PHP uses the JIT by default (`pcre.jit=1`, 7.0 and later). PCRE 8.38 of 5.6
is from 2015 and lacks the fixes of 8.39 to 8.45, for example the JIT bugs
CVE-2017-6004 and CVE-2019-20838 and the integer overflow CVE-2020-14155 (5.6 itself
does not use the JIT).
Every branch here carries the newest release instead
([`freebsd/pcre.conf`](freebsd/pcre.conf)): PCRE2 10.49 in 7.4 to 8.4 and PCRE 8.45,
the last PCRE1 release, in 5.6. The sync unpacks the release tarball (its SHA-256 is
the one in freebsd-ports `devel/pcre2` or `devel/pcre`) and imports it with
[`freebsd/pcre/import-pcre2.sh`](freebsd/pcre/import-pcre2.sh) (5.6:
[`import-pcre1.sh`](freebsd/pcre/import-pcre1.sh)) the way php-src does: the library
sources, PHP's own `config.h` (plus the defaults of the release it lacks, such as
`MAX_VARLOOKBEHIND` for 7.4 to 8.3), the list of sources in `ext/pcre/config0.m4`.
PHP renames the functions of its bundled PCRE in `main/php_compat.h`
(`pcre2_compile_8` becomes `php_pcre2_compile`), so a libpcre2 that Apache has loaded
does not take their calls; the list in php-src misses the functions added since
PCRE2 10.30 (and the JIT functions of PCRE 8.x), and `pcre2_substitute` of 10.49 calls
one of them, so the import renames those too. The `ext/pcre` tests pass as before;
the ones that print messages of the library expect the old and the new wording, as
php-src has them since 8.1 and 8.3 (`freebsd/pcre/tests-<version>.patch`). A newer
PCRE also brings its features to the old branches: PHP 7.4 with 10.49 knows
lookbehinds of limited variable length, such as `(?<=a{1,3})b`.

`--with-external-pcre` (5.6: `--with-pcre-regex=DIR`) still takes the library of
the system. `config-check.sh` leaves those options out when the PCRE of the tree is
not older than the one of the system, so the build needs no `pcre2` or `pcre`
package, and says so; a newer library in the system keeps the option. The daily
upstream check opens an issue for each new PCRE2 release.

## How updates happen

[`.github/workflows/sync.yml`](.github/workflows/sync.yml) runs every hour and
calls [`tools/sync.sh`](tools/sync.sh):

1. resolves the upstream commit of every target in
   [`freebsd/targets.conf`](freebsd/targets.conf) with `git ls-remote`;
2. skips targets whose branch already carries that commit and the same patch set;
3. otherwise rebuilds `freebsd/<version>`, mirrors Remi's branch, generates a
   tarball with [`tools/makedist.sh`](tools/makedist.sh) (Ubuntu 24.04 autoconf,
   bison and re2c) and publishes the releases.

A run can also be started by hand (Actions, "Sync FreeBSD branches", "Run
workflow"), optionally with `force`, a list of targets, or `notes_only`, which
rewrites the notes of the current releases without rebuilding anything (regular
runs do the same for targets that are up to date). The dated release carries the
full notes; `freebsd-<version>-latest` points to it. A second
build of the same upstream commit on the same day replaces that day's dated
release. Locally: `tools/sync.sh --local` in a clone of this repository builds the
branches without pushing.

### Build compatibility patches

Patches that only make a branch build and work on current FreeBSD go into
`freebsd/patches/<version>/compat-*.patch` (git format, `-p1`, with `Description:`
and `Origin:` lines on top). They are always applied, as the commit "Apply build
compatibility patches" right after the ports patches, and listed in the branch
README and the release notes; one that stops applying fails the build, so that it
gets reviewed.

| Version | Patch | What it fixes |
|---|---|---|
| 5.6 | [`compat-bison3.patch`](freebsd/patches/5.6/compat-bison3.patch) | parsers generated by bison 3.6+ (the tarballs use 3.8) report only "syntax error" and shift the `T_*` token numbers; now detailed errors and the token numbers of the php.net 5.6.40 tarball |
| 5.6 | [`compat-c99.patch`](freebsd/patches/5.6/compat-c99.patch) | clang 16+ (FreeBSD 14/15: clang 19) and gcc 14+ reject pre-C99 code: configure tests failed silently (no `getaddrinfo`, so no IPv6 name resolution; wrong `readdir_r` and `fopencookie` types, which broke the build; no `pread`/`pwrite`, ...), and four sources did not compile |
| 5.6 | [`compat-freetype-pkgconfig.patch`](freebsd/patches/5.6/compat-freetype-pkgconfig.patch) | FreeType without `freetype-config`: found through `pkg-config`, and the bundled GD is built with FreeType, so `imagettftext()` draws |
| 5.6 | [`compat-libxml2.patch`](freebsd/patches/5.6/compat-libxml2.patch) | libxml2 2.12+ (FreeBSD 15.1: 2.15) API changes |
| 5.6 | [`compat-oniguruma.patch`](freebsd/patches/5.6/compat-oniguruma.patch) | with the `oniguruma` package installed (7.4 and 8.x need it), its `oniguruma.h` shadowed the bundled one and `ext/mbstring` did not compile |
| 5.6 | [`compat-openssl3.patch`](freebsd/patches/5.6/compat-openssl3.patch) | OpenSSL 3: legacy provider, `tls://`, `OPENSSL_SSLV23_PADDING`, CSR public key |
| 7.4 | [`compat-c99.patch`](freebsd/patches/7.4/compat-c99.patch) | configure tests that clang 16+ and gcc 14+ reject (`write(2)` to stdout, functions in separate libraries) |
| 7.4 | [`compat-openssl3.patch`](freebsd/patches/7.4/compat-openssl3.patch) | OpenSSL 3: legacy provider, `OPENSSL_SSLV23_PADDING`, CSR public key |

### Interim backports

If an end-of-life branch needs a security fix before Remi Collet publishes one,
a git-format patch (`-p1`, with `Description:` and `Origin:` lines on top) can be
put into `freebsd/patches/<version>/backport-*.patch`. It is applied as an extra
commit, "Backport security fixes", and flagged in the branch README. Once the
upstream branch contains the same change (the patch applies in reverse), it is
skipped automatically, so the branch falls back to upstream's own fix.

### Token

The workflow pushes with the repository secret `SYNC_TOKEN` when it exists: a
fine-grained personal access token limited to this repository with **Contents**
and **Workflows** read/write. The default `GITHUB_TOKEN` is used otherwise, but it
may not push upstream history that touches `.github/workflows`, so some updates of
the `freebsd/8.x` branches could be rejected without `SYNC_TOKEN`.

## Credits and licenses

- This fork (branches, choice of FreeBSD ports patches, release tarballs and
  tooling): aZ, [azsupport.com](https://azsupport.com/): lease, setup and
  administration of FreeBSD and Linux dedicated web servers since 2004, with
  monthly managed support (24/7 monitoring, security patching, backups) for
  projects where downtime costs money.
- PHP: the PHP Group, PHP License (see `LICENSE` in each source branch).
- Security backports for end-of-life branches: Remi Collet,
  [remicollet/php-src-security](https://github.com/remicollet/php-src-security).
- FreeBSD ports patches: the FreeBSD ports maintainers, BSD-2-Clause.
- Tooling in this branch: BSD-2-Clause, see [LICENSE](LICENSE).
