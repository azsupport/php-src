#!/usr/bin/env python3
"""check-deps-links.py - look for missing libraries in the static link lines of
an extracted /usr/local/phpdeps bundle (tools/build-deps.sh).

For every .pc file of the bundle, the archives that `pkgconf --static --libs`
names are taken together; a symbol that they leave undefined but that another
archive of the bundle defines means that archive is missing from the link line
(as libhashkit was from libmemcached.pc). Symbols defined nowhere in the bundle
are left to the base system (libc, libthr, libc++, libz, ...) and not reported.

Usage: python3 tools/check-deps-links.py <dir that holds lib/ and lib/pkgconfig/> [more pkgconfig dirs]
The more dirs (colon separated) are for the .pc files of the base system that the
bundle's ones require (zlib, bzip2: /usr/libdata/pkgconfig on FreeBSD).
Needs nm (binutils or llvm) and pkgconf. Exit status 1 when something is missing.
"""
import os
import subprocess
import sys


def nm_symbols(archive):
    """Defined and undefined global symbols of the members of an archive."""
    out = subprocess.run(['nm', '-g', archive], capture_output=True, text=True).stdout
    defined, undefined = set(), set()
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] == 'U':
            undefined.add(parts[1])
        elif len(parts) == 3 and parts[1] not in ('U', 'w', 'v'):
            defined.add(parts[2])
    return defined, undefined


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    top = os.path.abspath(sys.argv[1])
    libdir = os.path.join(top, 'lib')
    pcdir = os.path.join(libdir, 'pkgconfig')
    archives = sorted(f for f in os.listdir(libdir) if f.endswith('.a'))
    syms = {a: nm_symbols(os.path.join(libdir, a)) for a in archives}
    definers = {}
    for a in archives:
        for s in syms[a][0]:
            definers.setdefault(s, set()).add(a)

    env = dict(os.environ, PKG_CONFIG_LIBDIR=pcdir + (':' + sys.argv[2] if len(sys.argv) == 3 else ''))
    env.pop('PKG_CONFIG_PATH', None)
    missing_any = False
    for pc in sorted(f[:-3] for f in os.listdir(pcdir) if f.endswith('.pc')):
        res = subprocess.run(['pkgconf', '--static', '--libs', pc], capture_output=True, text=True, env=env)
        if res.returncode != 0:
            print('%-20s pkgconf failed: %s' % (pc, res.stderr.strip()))
            missing_any = True
            continue
        # -lname, or an archive named by its path (as gdlib.pc names libiconv.a)
        line = []
        for t in res.stdout.split():
            a = 'lib%s.a' % t[2:] if t.startswith('-l') else os.path.basename(t) if t.endswith('.a') else None
            if a in syms and a not in line:
                line.append(a)
        if not line:
            continue
        defined = set().union(*(syms[a][0] for a in line))
        undefined = set().union(*(syms[a][1] for a in line)) - defined
        needs = {}
        for s in undefined:
            for a in definers.get(s, ()):
                needs.setdefault(a, set()).add(s)
        if needs:
            missing_any = True
            for a, ss in sorted(needs.items()):
                print('%-20s needs %-22s for %d symbols, e.g. %s' % (pc, a, len(ss), ' '.join(sorted(ss)[:4])))
    if not missing_any:
        print('every .pc of %s names the bundle archives its archives need' % top)
    return 1 if missing_any else 0


if __name__ == '__main__':
    sys.exit(main())
