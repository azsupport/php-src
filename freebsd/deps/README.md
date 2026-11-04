# Patches of a port, brought up to the release of its take line

`freebsd/deps.conf` can build a library of `/usr/local/phpdeps` from a new upstream
release before its FreeBSD port has it (a `take` line). The ports framework applies
the patches of the port to it; when one of them no longer applies,
`freebsd/deps/<name>-<version>/` holds all the patches of that port, the failing ones
brought up to the release, and the framework takes them from here instead
(`PATCHDIR`). [`tools/deps-take-check.sh`](../../tools/deps-take-check.sh) (workflow
"phpdeps take check") shows which patches apply.

| Directory | From | Changed |
|---|---|---|
| `libiconv-1.19.1` | `converters/libiconv/files` at the ports commit of `deps.conf` (libiconv 1.18) | `patch-include-iconv.h.in`: the context line `_LIBICONV_VERSION 0x0113` of 1.19 (it was `0x0112`); the other two as they are |

A directory goes with its take line, once the port has the version.
`libiconv-1.19.1` stays while its take line is commented out in `deps.conf`
(04.11.2026: releases are taken before their port only for a vulnerability that
touches us, or a bug we have): ready for a security release of libiconv 1.19.x.
