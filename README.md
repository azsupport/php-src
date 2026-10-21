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

Every branch is upstream plus exactly two commits:

1. **Apply curated FreeBSD ports patches**: taken from `lang/phpXY` in the
   [FreeBSD ports collection](https://github.com/freebsd/freebsd-ports); the patch
   files with a description and origin line are in [`freebsd/patches/`](freebsd/patches).
   The same commit removes the upstream `.github/` directory, so that php-src's own
   CI does not run in this fork (release tarballs never contain it anyway).
2. **README: describe the freebsd/X.Y branch**: a notes block on top of the original
   README, with the exact upstream commit (`Upstream-Commit:` trailer).

Remi Collet's branches are mirrored under their original names
(`PHP-5.6-security-backports-openssl11`, `PHP-7.4-security-backports`,
`PHP-8.1-security-backports`) and kept current by the workflow. The release tags
`php-5.6.40`, `php-7.4.33`, `php-8.1.34`, `php-8.2.34`, `php-8.3.35` and
`php-8.4.26` were mirrored once on 21.10.2026; newer official tags are not mirrored,
because pushing them would start php-src's tag-triggered CI here, but their full
history is part of the `freebsd/8.x` branches. `master` is the untouched fork point
of php/php-src and is not used.

### Which FreeBSD ports patches are applied

Only patches that matter for a monolithic build on FreeBSD:

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
- 5.6 only, `Zend/zend_compile.h`, `Zend/zend_execute.h`, `Zend/zend_list.[ch]`:
  pointer-arithmetic macros turned into inline functions (avoids undefined
  behaviour that newer clang miscompiles) and 64-bit resource list ids.

Not applied: ports patches that only serve the ports' split-extension packaging
(`configure.ac`, `acinclude.m4`, `ext/mysqli/*`, `ext/zlib/config0.m4`,
`ext/standard/image.c`, `ext/session/php_session.h`), other CPU architectures
(PowerPC `sljit`/`xxhash`), LibreSSL, and the 8.4 `ext/pcre/php_pcre.h` include
change, which can pick up a system `pcre2.h` instead of the bundled PCRE.

## Building on FreeBSD from a release tarball

The `freebsd-<version>-latest` release always carries the newest tarball of a
branch; dated releases (`freebsd-<version>-<YYYYMMDD>-<commit>`) are kept. The
version string is the upstream one (for example `7.4.33`); a tarball unpacks into
a directory that also carries the date and upstream commit, for example
`php-7.4.33-fbsd-20261021-bd7e19b2/`.

```sh
cd /root
fetch https://github.com/azsupport/php-src/releases/download/freebsd-7.4-latest/php-7.4-fbsd-latest.tar.xz
fetch https://github.com/azsupport/php-src/releases/download/freebsd-7.4-latest/php-7.4-fbsd-latest.tar.xz.sha256
sha256 -c `cut -d' ' -f1 php-7.4-fbsd-latest.tar.xz.sha256` php-7.4-fbsd-latest.tar.xz
tar xf php-7.4-fbsd-latest.tar.xz
cd php-7.4.33-fbsd-*/
sh /root/php-7.4.33/config.nice        # reuse the options of your previous build
make -j`sysctl -n hw.ncpu`
make install
```

The commands work in both `sh` and `csh`. `config.nice` is written by
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
workflow"), optionally with `force` or a list of targets. Locally:
`tools/sync.sh --local` in a clone of this repository builds the branches without
pushing.

The workflow pushes with the repository secret `SYNC_TOKEN` when it exists: a
fine-grained personal access token limited to this repository with **Contents**
and **Workflows** read/write. The default `GITHUB_TOKEN` is used otherwise, but it
may not push upstream history that touches `.github/workflows`, so some updates of
the `freebsd/8.x` branches could be rejected without `SYNC_TOKEN`.

## Credits and licenses

- PHP: the PHP Group, PHP License (see `LICENSE` in each source branch).
- Security backports for end-of-life branches: Remi Collet,
  [remicollet/php-src-security](https://github.com/remicollet/php-src-security).
- FreeBSD ports patches: the FreeBSD ports maintainers, BSD-2-Clause.
- Tooling in this branch: BSD-2-Clause, see [LICENSE](LICENSE).
