#!/bin/sh
# makedist.sh - build a release-style PHP source tarball from a git ref.
#
# The tarball contains the generated ./configure and the bison/re2c generated
# parsers and scanners, exactly like the tarballs on php.net, so a server only
# needs a C compiler and make (no autoconf, bison or re2c).
#
# Usage: tools/makedist.sh <git-ref> <output-dir> <name>
#   <name> becomes the top-level directory inside the tarball and the file name:
#   <output-dir>/<name>.tar.xz and <output-dir>/<name>.tar.xz.sha256
#
# Requires: git, autoconf (>= 2.68), bison (>= 3.0), re2c (>= 1.0), xz, sha256sum or sha256.

set -eu

ref="$1"
out="$2"
name="$3"

mkdir -p "$out"
out="$(cd "$out" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT INT TERM

git archive --format=tar --prefix="$name/" "$ref" | tar -x -C "$work"
cd "$work/$name"

# Generate parsers and scanners (PHP 7.4+ keeps the script in scripts/dev, 5.6 in the root).
if [ -f scripts/dev/genfiles ]; then
    sh scripts/dev/genfiles
elif [ -f genfiles ]; then
    sh genfiles
fi

# Generate ./configure; --force because this is not a git checkout any more.
./buildconf --force

# Drop build caches and CI configuration that release tarballs do not ship.
rm -rf autom4te.cache .github .circleci .cirrus.yml .travis.yml .appveyor.yml \
       azure azure-pipelines.yml appveyor travis
find . \( -name '*.orig' -o -name '*.rej' \) -exec rm -f {} +

[ -x configure ] || { echo "makedist: ./configure was not generated" >&2; exit 1; }

cd "$work"
tar -cf - "$name" | xz -9 > "$out/$name.tar.xz"
cd "$out"
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$name.tar.xz" > "$name.tar.xz.sha256"
else
    sha256 -r "$name.tar.xz" | awk '{print $1 "  " $2}' > "$name.tar.xz.sha256"
fi
echo "makedist: $out/$name.tar.xz"
