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
| [`freebsd/5.6`](https://github.com/azsupport/php-src/tree/freebsd/5.6) | 5.6.40 + backports | Remi Collet, [`PHP-5.6-security-backports-openssl11`](https://github.com/remicollet/php-src-security/tree/PHP-5.6-security-backports-openssl11) (builds with OpenSSL 1.1) | end of life 31.12.2018 | [freebsd-5.6-latest](https://github.com/azsupport/php-src/releases/tag/freebsd-5.6-latest) |

For the PHP security release of 21.10.2026 (CVE-2026-109618, CVE-2026-109619,
[announcement](https://www.php.net/archive/2026.php)): `freebsd/8.2`, `freebsd/8.3`
and `freebsd/8.4` carry the official fixed releases 8.2.35, 8.3.36 and 8.4.27.
`freebsd/7.4` and `freebsd/8.1` carry the commit "Avoid state corruption via bailout"
(Arnaud Le Blanc) from Remi Collet's branches, the minimal source backport that the
PHP security team provided for 7.4, 8.0 and 8.1. It is smaller than the complete fix
of 8.2+ (for example, it disables session upload progress in the code), so keep the
configuration mitigations from the announcement on these versions. `freebsd/5.6` has
no fix for these vulnerabilities.

Every branch is upstream plus exactly three commits:

1. **Apply curated FreeBSD ports patches**: taken from `lang/phpXY` in the
   [FreeBSD ports collection](https://github.com/freebsd/freebsd-ports); the patch
   files with a description and origin line are in [`freebsd/patches/`](freebsd/patches).
   The same commit removes the upstream `.github/` directory, so that php-src's own
   CI does not run in this fork (release tarballs never contain it anyway).
2. **Show the build id in the `php -v` banner**: a new `PHP_FORK_BUILD` macro is
   appended to the banner by C string-literal concatenation, so `php -v` shows the
   build date and upstream commit, for example
   `PHP 7.4.33 (cli) (built: ...) (fork: 20261021-fbsd-802c2107)`. `PHP_VERSION`
   stays the plain upstream `7.4.33`, so `phpversion()`, `version_compare()` and
   `PHP x.y.z` parsers are not disturbed. On 8.2+ the banner is shared by every SAPI
   (`php -v`, `php-fpm -v`); on 5.6/7.4 it is the CLI banner. `phpinfo()` shows the
   plain version, not the build id.
3. **README: describe the freebsd/X.Y branch**: a notes block on top of the original
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

```sh
cd /root
fetch https://github.com/azsupport/php-src/releases/download/freebsd-7.4-latest/php-7.4-fbsd-latest.tar.xz
fetch https://github.com/azsupport/php-src/releases/download/freebsd-7.4-latest/php-7.4-fbsd-latest.tar.xz.sha256
sha256 -c `cut -d' ' -f1 php-7.4-fbsd-latest.tar.xz.sha256` php-7.4-fbsd-latest.tar.xz
tar xf php-7.4-fbsd-latest.tar.xz
cd php-7.4.33-fbsd-*/
fetch https://raw.githubusercontent.com/azsupport/php-src/master/tools/config-check.sh
sh config-check.sh /usr/local/php74 /root/php-7.4.33/config.nice
sh config.installed.sh
make -j`sysctl -n hw.ncpu`
make install
php -v
```

[`tools/config-check.sh`](tools/config-check.sh) compares the options in an old
`config.nice` with those of the PHP that is actually installed (from `php -n -i`), as
a `config.nice` may come from a configure run that was never installed. The
installed build wins: the script lists the differences, if any, and always writes
`config.installed.sh` with the installed build's options into the current directory.

`php -v` then reports `PHP 7.4.33 (cli) (built: ...) (fork: 20261021-fbsd-802c2107)`.
The commands work in both `sh` and `csh`; the block has no comments on purpose,
because an interactive csh does not treat `#` as a comment. `config.nice` is written by
`configure` into every build directory and re-runs `./configure` with the same
options from the current directory. Restart php-fpm or Apache afterwards so that
no worker keeps running the old binary.

Building straight from a branch also works, but then autoconf, bison and re2c
are required (`./buildconf --force` first).

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
