#!/usr/bin/env python3
"""debian-fetch.py - the patches Debian (or Ubuntu) carries for source packages, in every suite.

For each source package asked for, the version of every suite of Debian that has
it (SUITES below), or with --distro ubuntu of every suite of Ubuntu (UBUNTU below):

  deb.debian.org       sid, experimental, testing, trixie, bookworm, bullseye, with
                       their -updates, -proposed-updates and -backports
  the security archive trixie-security, bookworm-security, bullseye-security
                       (deb.debian.org/debian-security; Debian LTS uses them too)
  archive.debian.org   buster, stretch, jessie (bullseye once it moves there), with
                       their -backports and security (buster/updates ...)
  Freexian's ELTS      deb.freexian.com/extended-lts: bullseye, buster, stretch,
                       jessie, shown as <codename>-elts
  Ondrej Sury          deb.sury.org (packages.sury.org/php for Debian, the PPA
                       ondrej/php for Ubuntu, built from the same debian/ of his):
                       the sources of the PPA, by name through the API of
                       Launchpad (as tools/upstream-check.py reads them), the newest
                       Ubuntu series of each version, shown as sury

and, for a package that none of them has any more, its last version on
snapshot.debian.org; "name=version" takes that version from snapshot.debian.org
as well. A name that is no source package but a binary one is taken as its
source package (the report says so).

Of every version, without the source tarball of upstream: debian/patches as it
is (with series), the other patch files of debian/ (debian/diff/...), debian/rules,
the head of debian/changelog (the entries of the last CHANGELOG_YEARS years, at
least CHANGELOG_MIN of them), the list of the files of debian/ and source.txt (the
entry of the index: version, format, files with their SHA-256, Vcs, where it was
taken from). For a source of format 1.0 (a .diff.gz), its changes outside
debian/ go to upstream.diff.

Layout of the output (--out DIR), one directory per suite (a version in several
suites is fetched once; git keeps the same files once):

  DIR/<package>/<suite>_<version>/   (the version without its epoch)
      source.txt  changelog  files.txt  rules  patches/  other/  upstream.diff

With --push the tree goes into the branch runs of azsupport/azsupport, under
distro/debian/<YYYY-MM-DD>/ (UTC), with an index.md per package (its suites and
versions of that day), committed and pushed with the token RUNS_TOKEN as
tools/runs-report.sh does; several runs may push at the same time, so a refused
push is made again on the new tip (the files of a version do not change).

With --distro ubuntu (UBUNTU below): the releases of archive.ubuntu.com (the
supported ones, the development one, and those in Ubuntu Pro's ESM: trusty,
xenial, bionic, focal) with their -security (security.ubuntu.com), -updates,
-proposed and -backports pockets, and the releases at their end of life of
old-releases.ubuntu.com from 14.04 on with -security and -updates (an older
release, or another pocket of them, when --suites names it); found in the
dists/ of both archives, newest first. The fixes of a release past its standard
support are in ESM, which is not public: source.txt says so, and gives the date
of the newest entry of the changelog (where the public history stops). A file
missing from its pool, a "name=version" and a package that no suite has any
more come from Launchpad (instead of snapshot.debian.org). The tree goes to
distro/ubuntu/<YYYY-MM-DD>/ of the branch runs.

Usage: python3 tools/debian-fetch.py --out DIR [--report FILE] [--suites LIST]
                                     [--distro debian|ubuntu] [--push] PACKAGE[=VERSION]...
  --out      where the tree is written (empty or new)
  --report   a summary in Markdown (the job summary, the report of the run)
  --suites   only these suites (names as above, separated by spaces or commas)
  --distro   debian (the default) or ubuntu
  --push     commit the tree into azsupport/azsupport (branch runs); RUNS_REMOTE
             (a path or URL) instead, for a test
"""

import argparse
import bz2
import concurrent.futures
import datetime
import email.utils
import functools
import gzip
import hashlib
import io
import json
import lzma
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

UA = "debian-fetch (azsupport/php-src)"
DEB = "https://deb.debian.org/debian"
SEC = "https://deb.debian.org/debian-security"
ARCHIVE = "https://archive.debian.org/debian"
ARCHIVE_SEC = "https://archive.debian.org/debian-security"
ELTS = "https://deb.freexian.com/extended-lts"
LAUNCHPAD = "https://api.launchpad.net/1.0"
SURY_PPA = "~ondrej/+archive/ubuntu/php"
SNAPSHOT = "https://snapshot.debian.org"

# The suites, in the order of the report: (the name shown, [(archive, dists/<dist>)]):
# the first candidate whose index is there is taken (a suite moves to
# archive.debian.org some time after its end; Freexian names its suites
# <codename>-lts or <codename>).
SUITES = (
    ("sid", [(DEB, "sid")]),
    ("experimental", [(DEB, "experimental")]),
    ("testing", [(DEB, "testing")]),
    ("trixie", [(DEB, "trixie")]),
    ("trixie-security", [(SEC, "trixie-security")]),
    ("trixie-updates", [(DEB, "trixie-updates")]),
    ("trixie-proposed-updates", [(DEB, "trixie-proposed-updates")]),
    ("trixie-backports", [(DEB, "trixie-backports")]),
    ("bookworm", [(DEB, "bookworm"), (ARCHIVE, "bookworm")]),
    ("bookworm-security", [(SEC, "bookworm-security"), (ARCHIVE_SEC, "bookworm-security")]),
    ("bookworm-updates", [(DEB, "bookworm-updates"), (ARCHIVE, "bookworm-updates")]),
    ("bookworm-proposed-updates", [(DEB, "bookworm-proposed-updates"), (ARCHIVE, "bookworm-proposed-updates")]),
    ("bookworm-backports", [(DEB, "bookworm-backports"), (ARCHIVE, "bookworm-backports")]),
    ("bullseye", [(DEB, "bullseye"), (ARCHIVE, "bullseye")]),
    ("bullseye-security", [(SEC, "bullseye-security"), (ARCHIVE_SEC, "bullseye-security")]),
    ("bullseye-updates", [(DEB, "bullseye-updates"), (ARCHIVE, "bullseye-updates")]),
    ("bullseye-proposed-updates", [(DEB, "bullseye-proposed-updates"), (ARCHIVE, "bullseye-proposed-updates")]),
    ("bullseye-backports", [(DEB, "bullseye-backports"), (ARCHIVE, "bullseye-backports")]),
    ("bullseye-elts", [(ELTS, "bullseye-lts"), (ELTS, "bullseye")]),
    ("buster", [(ARCHIVE, "buster"), (DEB, "buster")]),
    ("buster-security", [(ARCHIVE_SEC, "buster/updates"), (SEC, "buster/updates")]),
    ("buster-backports", [(ARCHIVE, "buster-backports")]),
    ("buster-elts", [(ELTS, "buster-lts"), (ELTS, "buster")]),
    ("stretch", [(ARCHIVE, "stretch")]),
    ("stretch-security", [(ARCHIVE_SEC, "stretch/updates")]),
    ("stretch-backports", [(ARCHIVE, "stretch-backports")]),
    ("stretch-elts", [(ELTS, "stretch-lts"), (ELTS, "stretch")]),
    ("jessie", [(ARCHIVE, "jessie")]),
    ("jessie-security", [(ARCHIVE_SEC, "jessie/updates")]),
    ("jessie-backports", [(ARCHIVE, "jessie-backports")]),
    ("jessie-elts", [(ELTS, "jessie-lts"), (ELTS, "jessie")]),
    # no index: the sources are asked for by name (sury_sources)
    ("sury", [(LAUNCHPAD, SURY_PPA)]),
)
COMPONENTS = ("main", "contrib", "non-free")
CHANGELOG_YEARS = 6
CHANGELOG_MIN = 10
CHANGELOG_MAX_LINES = 4000
FILE_LIMIT = 40 * 1024 * 1024        # a bigger file is left out (named in files.txt)
NAME = re.compile(r"^[a-z0-9][a-z0-9+.-]+$")
VERSION = re.compile(r"^[A-Za-z0-9.+~:-]+$")
RUNS_URL = "https://x-access-token:%s@github.com/azsupport/azsupport.git"
RUNS_DIR = "distro/debian"

# Ubuntu (--distro ubuntu): main() puts its suites into SUITES, its components into
# COMPONENTS and its directory into RUNS_DIR
UBUNTU = "https://archive.ubuntu.com/ubuntu"
UBUNTU_SEC = "https://security.ubuntu.com/ubuntu"
UBUNTU_OLD = "https://old-releases.ubuntu.com/ubuntu"
UBUNTU_COMPONENTS = ("main", "restricted", "universe", "multiverse")
UBUNTU_POCKETS = ("", "-security", "-updates", "-proposed", "-backports")
UBUNTU_OLD_POCKETS = ("", "-security", "-updates")     # of a release at its end of life, by default
UBUNTU_OLDEST = (14, 4)                                 # older releases only when --suites names them
# the end of the standard support of the releases in ESM (Ubuntu Pro): their later fixes are not public
UBUNTU_ESM = {"trusty": "2019-04", "xenial": "2021-04", "bionic": "2023-05", "focal": "2025-05"}
UBUNTU_RUNS_DIR = "distro/ubuntu"
UBUNTU_THREADS = 8                                      # indexes and versions read at once
LAUNCHPAD = "https://api.launchpad.net/1.0/ubuntu/+archive/primary"
LAUNCHPAD_FILE = "https://launchpad.net/ubuntu/+archive/primary/+sourcefiles/%s/%s/%s"

DISTRO = "debian"
DEFAULT = None          # the suites read when --suites is empty (None: all of SUITES)
RELEASES = {}           # Ubuntu: codename -> (version, archive)

warnings = []


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def warn(msg):
    warnings.append(msg)
    print(("::warning title=debian-fetch::" if os.environ.get("GITHUB_ACTIONS") else "warning: ") + msg,
          file=sys.stderr, flush=True)


def get(url, tries=3):
    """The body of url (bytes); None on 404/410 (not there)."""
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=120) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code in (404, 410):
                return None
            err = e
        except Exception as e:  # noqa: BLE001
            err = e
        if i + 1 < tries:
            time.sleep(3 * (i + 1))
    raise RuntimeError("%s: %s" % (url, err))


def deb822(text):
    """The stanzas of a Debian control file (Sources, .dsc): [{field: value}]."""
    out, cur, key = [], {}, None
    for line in text.splitlines():
        if not line.strip():
            if cur:
                out.append(cur)
            cur, key = {}, None
            continue
        if line[0] in " \t":
            if key:
                cur[key] += "\n" + line.strip()
            continue
        k, _, v = line.partition(":")
        key = k.strip()
        cur[key] = v.strip()
    if cur:
        out.append(cur)
    return out


def unsign(text):
    """A .dsc without its OpenPGP armor."""
    if "-----BEGIN PGP SIGNED MESSAGE-----" not in text:
        return text
    body = text.split("-----BEGIN PGP SIGNED MESSAGE-----", 1)[1]
    body = body.split("\n\n", 1)[1] if "\n\n" in body else body
    return body.split("-----BEGIN PGP SIGNATURE-----", 1)[0]


# dpkg's comparison of versions (deb-version(7))
def _order(c):
    if c == "~":
        return -1
    if c.isdigit():
        return 0
    if c.isalpha():
        return ord(c)
    return ord(c) + 256


def _cmp_part(a, b):
    while a or b:
        na = re.match(r"^[^\d]*", a).group(0)
        nb = re.match(r"^[^\d]*", b).group(0)
        a, b = a[len(na):], b[len(nb):]
        for i in range(max(len(na), len(nb))):
            ca = _order(na[i]) if i < len(na) else 0
            cb = _order(nb[i]) if i < len(nb) else 0
            if ca != cb:
                return -1 if ca < cb else 1
        da = re.match(r"^\d*", a).group(0)
        db = re.match(r"^\d*", b).group(0)
        a, b = a[len(da):], b[len(db):]
        ia, ib = int(da or 0), int(db or 0)
        if ia != ib:
            return -1 if ia < ib else 1
    return 0


def vercmp(a, b):
    def split(v):
        e, _, rest = v.rpartition(":") if ":" in v else ("0", "", v)
        u, _, r = rest.rpartition("-") if "-" in rest else (rest, "", "")
        return int(e or 0), u, r
    ea, ua, ra = split(a)
    eb, ub, rb = split(b)
    if ea != eb:
        return -1 if ea < eb else 1
    return _cmp_part(ua, ub) or _cmp_part(ra, rb)


def read_index(base, dist):
    """The source stanzas of dists/<dist> of an archive (all components), or None
    when the suite is not there."""
    stanzas, found = [], False
    for comp in COMPONENTS:
        data = None
        for ext, unpack in (("xz", lzma.decompress), ("gz", gzip.decompress), ("bz2", bz2.decompress), ("", None)):
            url = "%s/dists/%s/%s/source/Sources%s" % (base, dist, comp, "." + ext if ext else "")
            raw = get(url)
            if raw is None:
                continue
            data = unpack(raw) if unpack else raw
            break
        if data is None:
            if comp == "main":
                return None
            continue
        found = True
        for s in deb822(data.decode("utf-8", "replace")):
            s["_base"] = base
            s["_dist"] = dist
            s["_component"] = comp
            stanzas.append(s)
    return stanzas if found else None


def read_index_filtered(base, dist, names):
    """read_index for the big indexes of Ubuntu: (the stanzas that may be of names,
    the number of all of them), or None when the suite is not there."""
    stanzas, total, found = [], 0, False
    for comp in COMPONENTS:
        data = None
        for ext, unpack in (("xz", lzma.decompress), ("gz", gzip.decompress), ("bz2", bz2.decompress), ("", None)):
            raw = get("%s/dists/%s/%s/source/Sources%s" % (base, dist, comp, "." + ext if ext else ""))
            if raw is None:
                continue
            data = unpack(raw) if unpack else raw
            break
        if data is None:
            if comp == "main":
                return None
            continue
        found = True
        for para in re.split(r"\n[ \t]*\n", data.decode("utf-8", "replace")):
            if not para.strip():
                continue
            total += 1
            if not any(n in para for n in names):
                continue
            for s in deb822(para):
                s["_base"] = base
                s["_dist"] = dist
                s["_component"] = comp
                stanzas.append(s)
    return (stanzas, total) if found else None


def ubuntu_suites():
    """The suites of Ubuntu, newest release first ([(suite, [(archive, dist)])]), and
    those read by default: the releases of archive.ubuntu.com with every pocket, those
    of old-releases.ubuntu.com from UBUNTU_OLDEST on with UBUNTU_OLD_POCKETS."""
    found = {}
    for base in (UBUNTU, UBUNTU_OLD):
        try:
            raw = get(base + "/dists/")
        except RuntimeError as e:
            warn("%s/dists/: %s" % (base, e))
            continue
        for name in re.findall(r'href="([a-z]+)/"', (raw or b"").decode("utf-8", "replace")):
            if name != "devel" and name not in found:
                found[name] = base
    releases = []
    for name, base in found.items():
        try:
            rel = get("%s/dists/%s/Release" % (base, name))
        except RuntimeError as e:
            warn("%s %s: %s" % (name, base, e))
            continue
        m = re.search(r"^Version:\s*(\d+)\.(\d+)", (rel or b"").decode("utf-8", "replace"), re.M)
        if not m:
            warn("%s/dists/%s/Release: no version, left out" % (base, name))
            continue
        releases.append((name, (int(m.group(1)), int(m.group(2))), base))
    releases.sort(key=lambda r: r[1], reverse=True)
    suites, default = [], set()
    for name, ver, base in releases:
        RELEASES[name] = ("%d.%02d" % ver, base)
        old = base == UBUNTU_OLD
        for pocket in UBUNTU_POCKETS:
            suite = name + pocket
            if old:
                cands = [(UBUNTU_OLD, suite), (UBUNTU, suite)]
            elif pocket == "-security":
                cands = [(UBUNTU_SEC, suite), (UBUNTU, suite), (UBUNTU_OLD, suite)]
            else:
                cands = [(UBUNTU, suite), (UBUNTU_OLD, suite)]
            suites.append((suite, cands))
            if ver >= UBUNTU_OLDEST and (not old or pocket in UBUNTU_OLD_POCKETS):
                default.add(suite)
    return tuple(suites), default


def ubuntu_notes(suite, staged):
    """What source.txt says of a version of Ubuntu: the date of the newest entry of
    its changelog, and whether its release still gets public fixes."""
    notes = []
    try:
        text = open(os.path.join(staged, "changelog"), encoding="utf-8", errors="replace").read()
        m = re.search(r"^ -- .*?>\s+(.+)$", text, re.M)
        notes.append("Date: %s" % email.utils.parsedate_to_datetime(m.group(1).strip()).date().isoformat())
    except (OSError, AttributeError, TypeError, ValueError):
        pass
    name = re.sub(r"-(security|updates|proposed|backports)$", "", suite)
    if name in UBUNTU_ESM:
        notes.append("Support: %s is in ESM since %s: its later fixes are in Ubuntu Pro, not public; "
                     "this is its last public version in this pocket" % (name, UBUNTU_ESM[name]))
    elif RELEASES.get(name, ("", ""))[1] == UBUNTU_OLD:
        notes.append("Support: %s is at its end of life (old-releases.ubuntu.com): no fixes after this" % name)
    return notes


def launchpad_sources(src, version=None):
    """The publications of a source package in Ubuntu (Launchpad), every series and pocket."""
    q = {"ws.op": "getPublishedSources", "source_name": src, "exact_match": "true", "ws.size": "300"}
    if version:
        q["version"] = version
    url, out = "%s?%s" % (LAUNCHPAD, urllib.parse.urlencode(q)), []
    while url:
        raw = get(url)
        if raw is None:
            break
        data = json.loads(raw)
        out += data.get("entries", [])
        url = data.get("next_collection_link")
    return out


def launchpad_latest(src):
    best = None
    for e in launchpad_sources(src):
        v = e.get("source_package_version")
        if v and (best is None or vercmp(v, best) > 0):
            best = v
    return best


def from_launchpad(fetcher, src, version):
    entries = launchpad_sources(src, version)
    if not entries:
        raise RuntimeError("Launchpad has no %s %s" % (src, version))
    e = entries[0]
    urls = {}
    for u in json.loads(get(e["self_link"] + "?ws.op=sourceFileUrls") or b"[]"):
        urls[urllib.parse.unquote(u.rsplit("/", 1)[1])] = u
    dsc = [n for n in urls if n.endswith(".dsc")]
    if not dsc:
        raise RuntimeError("Launchpad: no .dsc of %s %s" % (src, version))
    st = deb822(unsign((get(urls[dsc[0]]) or b"").decode("utf-8", "replace")))
    if not st:
        raise RuntimeError("Launchpad: %s unreadable" % dsc[0])
    files = checksums(st[0])
    sizes = {f[0]: (f[1], f[2]) for f in files}

    def getter(name):
        body = get(urls.get(name) or LAUNCHPAD_FILE % (src, urllib.parse.quote(version), name))
        if body is None or len(body) != sizes[name][0] or not digest_ok(body, sizes[name][1]):
            raise RuntimeError("Launchpad %s: missing, or size or SHA-256 differs from the .dsc" % name)
        return body

    series = e.get("distro_series_link", "").rstrip("/").rsplit("/", 1)[-1]
    where = "Launchpad: %s %s (%s %s, %s)" % (src, version, series, e.get("pocket", "?"), e.get("status", "?"))
    dest = fetcher.write(src, "launchpad", version, st[0].get("Format", ""), where, files, getter,
                         stanza_fields(st[0]))
    return version, st[0].get("Format", ""), dest


def checksums(stanza):
    """[(name, size, sha256)] of a Sources entry or .dsc; without Checksums-Sha256 (the
    indexes of the newest releases of Ubuntu), "sha512:<hex>" of Checksums-Sha512."""
    out = []
    for line in stanza.get("Checksums-Sha256", "").splitlines():
        p = line.split()
        if len(p) == 3:
            out.append((p[2], int(p[1]), p[0]))
    if not out:
        for line in stanza.get("Checksums-Sha512", "").splitlines():
            p = line.split()
            if len(p) == 3:
                out.append((p[2], int(p[1]), "sha512:" + p[0]))
    return out


def digest_ok(data, sha):
    """Whether data has the checksum of checksums(): a SHA-256, or "sha512:<hex>"."""
    if sha.startswith("sha512:"):
        return hashlib.sha512(data).hexdigest() == sha[len("sha512:"):]
    return hashlib.sha256(data).hexdigest() == sha


def debian_file(names):
    """The name of the Debian part of a source (debian tarball or .diff.gz), or None (native)."""
    for n in names:
        if re.search(r"\.debian\.tar\.(xz|gz|bz2|lzma)$", n) or n.endswith(".diff.gz"):
            return n
    return None


def safe(path):
    """A relative path without .. (None if it is not one)."""
    parts = [p for p in path.split("/") if p not in ("", ".")]
    if not parts or any(p == ".." for p in parts):
        return None
    return "/".join(parts)


def changelog_head(text):
    """The newest entries of a debian/changelog: CHANGELOG_YEARS years, at least CHANGELOG_MIN."""
    cutoff = datetime.date.today().replace(year=datetime.date.today().year - CHANGELOG_YEARS)
    out, n = [], 0
    for line in text.splitlines():
        out.append(line)
        if line.startswith(" -- "):
            n += 1
            m = re.search(r">\s+(.+)$", line)
            try:
                day = email.utils.parsedate_to_datetime(m.group(1).strip()).date()
            except (AttributeError, TypeError, ValueError):
                day = None
            if n >= CHANGELOG_MIN and day is not None and day < cutoff:
                break
        if len(out) >= CHANGELOG_MAX_LINES:
            out.append("... (cut at %d lines)" % CHANGELOG_MAX_LINES)
            break
    return "\n".join(out).rstrip() + "\n"


def put(dest, rel, data, listing):
    rel = safe(rel)
    if rel is None:
        return
    if len(data) > FILE_LIMIT:
        listing.append("%s (%d bytes, sha256 %s: left out, bigger than %d)" % (
            rel, len(data), hashlib.sha256(data).hexdigest(), FILE_LIMIT))
        return
    path = os.path.join(dest, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def unpack_debian_tar(raw, dest):
    """debian/patches, the other patch files of debian/, rules and the changelog head
    of a debian tarball into dest; the list of the files of debian/."""
    listing, files = [], []
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:*") as t:
        for m in t.getmembers():
            rel = safe(m.name)
            if rel is None or not rel.startswith("debian/"):
                continue
            sub = rel[len("debian/"):]
            if m.issym() or m.islnk():
                files.append("%s -> %s" % (sub, m.linkname))
                continue
            if not m.isfile():
                continue
            files.append("%s (%d)" % (sub, m.size))
            want = None
            if sub.startswith("patches/"):
                want = sub
            elif sub == "changelog" or sub == "rules":
                want = sub
            elif re.search(r"\.(patch|diff|dpatch)$", sub) or sub.startswith("diff/"):
                want = "other/" + sub
            if want is None:
                continue
            data = t.extractfile(m).read()
            if want == "changelog":
                data = changelog_head(data.decode("utf-8", "replace")).encode("utf-8")
            put(dest, want, data, listing)
    return files, listing


def unpack_diff_gz(raw, dest):
    """A source of format 1.0: the files it adds under debian/ (patches, rules,
    changelog head) into dest; its changes outside debian/ to upstream.diff, and to
    a debian/ of upstream's own to debian.diff."""
    lines = gzip.decompress(raw).decode("utf-8", "replace").splitlines(keepends=True)
    listing, files, upstream, debdiff = [], [], [], []
    hunk = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
    i = 0
    while i < len(lines):
        if not (lines[i].startswith("--- ") and i + 1 < len(lines) and lines[i + 1].startswith("+++ ")):
            i += 1
            continue
        start = i
        target = lines[i + 1][4:].split("\t")[0].strip()
        rel = safe(target.split("/", 1)[1]) if "/" in target else None
        i += 2
        added, new = [], True
        while i < len(lines):
            m = hunk.match(lines[i])
            if not m:
                break
            old_n = int(m.group(2)) if m.group(2) is not None else 1
            new_n = int(m.group(4)) if m.group(4) is not None else 1
            if int(m.group(1)) != 0 or old_n != 0:
                new = False
            i += 1
            while i < len(lines) and (old_n > 0 or new_n > 0):
                line = lines[i]
                if line.startswith("\\"):
                    if added:
                        added[-1] = added[-1].rstrip("\n")
                elif line.startswith("+"):
                    added.append(line[1:])
                    new_n -= 1
                elif line.startswith("-"):
                    old_n -= 1
                else:
                    old_n -= 1
                    new_n -= 1
                i += 1
            if i < len(lines) and lines[i].startswith("\\"):
                if added:
                    added[-1] = added[-1].rstrip("\n")
                i += 1
        section = lines[start:i]
        if rel is None:
            continue
        if not rel.startswith("debian/"):
            upstream.extend(section)
            continue
        sub = rel[len("debian/"):]
        if not new:
            debdiff.extend(section)
            files.append("%s (changed)" % sub)
            continue
        data = "".join(added)
        files.append("%s (%d)" % (sub, len(data)))
        if sub.startswith("patches/") or sub == "rules":
            put(dest, sub, data.encode("utf-8"), listing)
        elif sub == "changelog":
            put(dest, sub, changelog_head(data).encode("utf-8"), listing)
        elif re.search(r"\.(patch|diff|dpatch)$", sub) or sub.startswith("diff/"):
            put(dest, "other/" + sub, data.encode("utf-8"), listing)
    if upstream:
        put(dest, "upstream.diff", "".join(upstream).encode("utf-8"), listing)
    if debdiff:
        put(dest, "debian.diff", "".join(debdiff).encode("utf-8"), listing)
    return files, listing


def dirname(suite, version):
    v = version.split(":", 1)[1] if ":" in version else version
    return "%s_%s" % (suite, re.sub(r"[^A-Za-z0-9.+~_-]", "_", v))


class Fetcher:
    """Each version is fetched and unpacked once (into a staging directory), then
    copied to the directory of every suite that has it, with a source.txt of its own."""

    def __init__(self, out):
        self.out = out
        self.stage = tempfile.mkdtemp(prefix="debian-fetch-")
        self.cache = {}           # (source, version) -> (staged directory, [source.txt lines])
        self.lock = threading.Lock()
        self.key_locks = {}       # Ubuntu fetches in threads: one fetch of a version at a time

    def write(self, src, suite, version, fmt, where, files, getter, fields):
        with self.lock:
            key_lock = self.key_locks.setdefault((src, version), threading.Lock())
        with key_lock:
            return self._write(src, suite, version, fmt, where, files, getter, fields)

    def _write(self, src, suite, version, fmt, where, files, getter, fields):
        dest = os.path.join(self.out, src, dirname(suite, version))
        key = (src, version)
        if key not in self.cache:
            staged = tempfile.mkdtemp(dir=self.stage)
            name = debian_file([f[0] for f in files])
            notes, content, listing = [], [], []
            if name is None:
                notes.append("Note: no debian tarball or .diff.gz (format %s): nothing to take" % (fmt or "?"))
            else:
                raw = getter(name)
                if name.endswith(".diff.gz"):
                    content, listing = unpack_diff_gz(raw, staged)
                else:
                    content, listing = unpack_debian_tar(raw, staged)
                notes.append("Debian part: %s (%d bytes, sha256 %s)" % (
                    name, len(raw), hashlib.sha256(raw).hexdigest()))
            with open(os.path.join(staged, "files.txt"), "w") as f:
                f.write("".join("%s\n" % x for x in sorted(content) + listing))
            self.cache[key] = (staged, notes)
        staged, notes = self.cache[key]
        if os.path.exists(dest):
            shutil.rmtree(dest)
        shutil.copytree(staged, dest)
        info = ["Source: %s" % src, "Version: %s" % version, "Format: %s" % (fmt or "?"),
                "Suite: %s" % suite, "From: %s" % where] + notes + fields
        if DISTRO == "ubuntu":
            info[5:5] = ubuntu_notes(suite, staged)
        info.append("Files of the source:")
        info += ["  %s %d %s" % f for f in files]
        with open(os.path.join(dest, "source.txt"), "w") as f:
            f.write("\n".join(info) + "\n")
        return dest

    def close(self):
        shutil.rmtree(self.stage, ignore_errors=True)


def stanza_fields(s):
    keep = ("Homepage", "Vcs-Git", "Vcs-Browser", "Maintainer", "Directory")
    return ["%s: %s" % (k, s[k]) for k in keep if k in s]


def from_suite(fetcher, src, suite, s):
    version, fmt = s.get("Version", "?"), s.get("Format", "")
    files = checksums(s)
    base, directory = s["_base"], s.get("Directory", "")
    sizes = {f[0]: (f[1], f[2]) for f in files}
    sha1 = {}
    for line in s.get("Checksums-Sha1", "").splitlines():
        p = line.split()
        if len(p) == 3:
            sha1[p[2]] = p[0]
    # where the file may be: the archive of the index, the other archives of the suite
    # (a suite being moved to archive.debian.org), snapshot.debian.org by its SHA-1
    bases = [base] + [b for b, _ in dict(SUITES)[suite] if b != base]

    def getter(name):
        size, sha = sizes[name]
        urls = ["%s/%s/%s" % (b, directory, name) for b in bases]
        if DISTRO == "ubuntu":
            urls.append(LAUNCHPAD_FILE % (src, urllib.parse.quote(version), name))
        elif name in sha1:
            urls.append("%s/file/%s" % (SNAPSHOT, sha1[name]))
        tried = []
        for url in urls:
            try:
                raw = get(url)
            except RuntimeError as e:
                tried.append(str(e))
                continue
            if raw is None:
                tried.append("%s: not found" % url)
                continue
            if len(raw) != size or not digest_ok(raw, sha):
                tried.append("%s: size or SHA-256 differs from the index" % url)
                continue
            if url != urls[0]:
                log("%s: taken from %s" % (name, url))
            return raw
        raise RuntimeError("; ".join(tried))

    where = "%s dists/%s/%s" % (base, s["_dist"], s["_component"])
    dest = fetcher.write(src, suite, version, fmt, where, files, getter, stanza_fields(s))
    return version, fmt, dest


def from_snapshot(fetcher, src, version):
    q = urllib.parse.quote
    raw = get("%s/mr/package/%s/%s/srcfiles?fileinfo=1" % (SNAPSHOT, q(src), q(version)))
    if raw is None:
        raise RuntimeError("snapshot.debian.org has no %s %s" % (src, version))
    data = json.loads(raw)
    names = {}
    for h in data.get("result", []):
        for fi in data.get("fileinfo", {}).get(h["hash"], []):
            names.setdefault(fi["name"], (h["hash"], fi.get("size", 0), fi.get("path", "")))
    files = [(n, names[n][1], "sha1:" + names[n][0]) for n in sorted(names)]

    def getter(name):
        sha1 = names[name][0]
        body = get("%s/file/%s" % (SNAPSHOT, sha1))
        if body is None or hashlib.sha1(body).hexdigest() != sha1:
            raise RuntimeError("snapshot.debian.org %s: missing or SHA-1 differs" % name)
        return body

    fmt, extra = "", []
    dsc = [n for n in names if n.endswith(".dsc")]
    if dsc:
        st = deb822(unsign(getter(dsc[0]).decode("utf-8", "replace")))
        if st:
            fmt = st[0].get("Format", "")
            extra = stanza_fields(st[0])
    where = "%s/package/%s/%s/ (pool %s)" % (SNAPSHOT, src, version, names[dsc[0]][2] if dsc else "?")
    dest = fetcher.write(src, "snapshot", version, fmt, where, files, getter, extra)
    return version, fmt, dest


def snapshot_latest(src):
    raw = get("%s/mr/package/%s/" % (SNAPSHOT, urllib.parse.quote(src)))
    if raw is None:
        return None
    versions = [r["version"] for r in json.loads(raw).get("result", [])]
    best = None
    for v in versions:
        if best is None or vercmp(v, best) > 0:
            best = v
    return best


def sury_sources(name):
    """The publications of the source <name> in the PPA of Ondrej Sury: one per version
    (without its +ubuntuNN.NN... suffix), that of the newest Ubuntu series."""
    url = "%s/%s?ws.op=getPublishedSources&source_name=%s&exact_match=true&status=Published" % (
        LAUNCHPAD, SURY_PPA, urllib.parse.quote(name))
    entries = []
    while url:
        raw = get(url)
        if raw is None:
            break
        data = json.loads(raw)
        entries += data.get("entries", [])
        url = data.get("next_collection_link")
    best = {}
    for e in entries:
        v = e.get("source_package_version", "")
        if e.get("source_package_name") != name or not v:
            continue
        base = re.sub(r"\+(ubuntu|deb)\d.*$", "", v)
        if base not in best or vercmp(v, best[base]["source_package_version"]) > 0:
            best[base] = e
    return sorted(best.values(), key=functools.cmp_to_key(
        lambda x, y: vercmp(x["source_package_version"], y["source_package_version"])))


def from_sury(fetcher, src, pub):
    """A publication of the PPA of Ondrej Sury: its .dsc, then the files it names,
    checked against its SHA-256."""
    version = pub["source_package_version"]
    raw = get(pub["self_link"] + "?ws.op=sourceFileUrls")
    urls = {urllib.parse.unquote(u.rsplit("/", 1)[-1]): u for u in (json.loads(raw) if raw else [])}
    dsc = sorted(n for n in urls if n.endswith(".dsc"))
    if not dsc:
        raise RuntimeError("no .dsc among the files of the PPA: %s" % " ".join(sorted(urls)))
    body = get(urls[dsc[0]])
    if body is None:
        raise RuntimeError("%s: not found" % urls[dsc[0]])
    st = deb822(unsign(body.decode("utf-8", "replace")))
    st = st[0] if st else {}
    files = checksums(st)
    sizes = {f[0]: (f[1], f[2]) for f in files}

    def getter(name):
        if name not in urls:
            raise RuntimeError("%s: not among the files of the PPA" % name)
        data = get(urls[name])
        if data is None:
            raise RuntimeError("%s: not found" % urls[name])
        size, sha = sizes[name]
        if len(data) != size or hashlib.sha256(data).hexdigest() != sha:
            raise RuntimeError("%s: size or SHA-256 differs from the .dsc" % name)
        return data

    series = (pub.get("distro_series_link") or "").rstrip("/").rsplit("/", 1)[-1]
    where = "Launchpad, PPA ondrej/php (https://launchpad.net/%s), Ubuntu %s, published %s" % (
        SURY_PPA, series or "?", (pub.get("date_published") or pub.get("date_created") or "?")[:10])
    dest = fetcher.write(src, "sury", version, st.get("Format", ""), where, files, getter,
                         stanza_fields(st))
    return version, st.get("Format", ""), dest


def index_md(pkgdir, src, day):
    if DISTRO == "ubuntu":
        return index_md_ubuntu(pkgdir, src, day)
    rows = []
    for d in sorted(os.listdir(pkgdir)):
        p = os.path.join(pkgdir, d, "source.txt")
        if not os.path.isfile(p):
            continue
        info = dict(line.split(": ", 1) for line in open(p).read().splitlines() if ": " in line)
        rows.append((d, info.get("Suite", "?"), info.get("Version", "?"), info.get("Format", "?")))
    order = {s[0]: i for i, s in enumerate(SUITES)}
    rows.sort(key=lambda r: (order.get(r[1], len(order)), r[2]))
    lines = ["# %s: Debian, %s" % (src, day), "",
             "Written by tools/debian-fetch.py of azsupport/php-src (workflow debian-fetch.yml).", "",
             "| suite | version | format | directory |", "|---|---|---|---|"]
    lines += ["| %s | %s | %s | [%s](%s/) |" % (r[1], r[2], r[3], r[0], r[0]) for r in rows]
    with open(os.path.join(pkgdir, "index.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def index_md_ubuntu(pkgdir, src, day):
    rows = []
    for d in sorted(os.listdir(pkgdir)):
        p = os.path.join(pkgdir, d, "source.txt")
        if not os.path.isfile(p):
            continue
        info = dict(line.split(": ", 1) for line in open(p).read().splitlines() if ": " in line)
        support = info.get("Support", "")
        rows.append((d, info.get("Suite", "?"), info.get("Version", "?"), info.get("Format", "?"),
                     info.get("Date", "?"), "ESM, not public after it" if " ESM " in support
                     else "end of life" if "end of life" in support else ""))
    order = {s[0]: i for i, s in enumerate(SUITES)}
    rows.sort(key=lambda r: (order.get(r[1], len(order)), r[2]))
    lines = ["# %s: Ubuntu, %s" % (src, day), "",
             "Written by tools/debian-fetch.py of azsupport/php-src (workflow debian-fetch.yml, distro ubuntu).",
             "Date: of the newest entry of the changelog of the version. ESM: the release is past its standard",
             "support, its later fixes are in Ubuntu Pro and not public.", "",
             "| suite | version | format | date | support | directory |", "|---|---|---|---|---|---|"]
    lines += ["| %s | %s | %s | %s | %s | [%s](%s/) |" % (r[1], r[2], r[3], r[4], r[5], r[0], r[0]) for r in rows]
    with open(os.path.join(pkgdir, "index.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def push(out, day, packages, run):
    """Commit <out> into the branch runs of azsupport/azsupport, RUNS_DIR/<day>/."""
    remote = os.environ.get("RUNS_REMOTE") or (RUNS_URL % os.environ["RUNS_TOKEN"]
                                               if os.environ.get("RUNS_TOKEN") else None)
    if not remote:
        warn("RUNS_TOKEN is not set: nothing pushed")
        return False
    target = "%s/%s" % (RUNS_DIR, day)

    def git(*args, cwd=None, check=True):
        r = subprocess.run(("git",) + args, cwd=cwd, capture_output=True, text=True)
        if check and r.returncode:
            raise RuntimeError("git %s: %s" % (args[0], re.sub(r"x-access-token:[^@]*@", "x-access-token:***@",
                                                             (r.stderr or r.stdout).strip())[-500:]))
        return r

    for attempt in range(1, 7):
        work = tempfile.mkdtemp()
        try:
            repo = os.path.join(work, "r")
            git("clone", "-q", "--depth", "1", "--filter=blob:none", "--sparse", "--branch", "runs",
                "--single-branch", remote, repo)
            git("sparse-checkout", "set", target, cwd=repo)
            for src in sorted(os.listdir(out)):
                dst = os.path.join(repo, target, src)
                for d in sorted(os.listdir(os.path.join(out, src))):
                    if os.path.exists(os.path.join(dst, d)):
                        shutil.rmtree(os.path.join(dst, d))
                    shutil.copytree(os.path.join(out, src, d), os.path.join(dst, d))
                index_md(dst, src, day)
            git("add", "-A", target, cwd=repo)
            if not git("status", "--porcelain", cwd=repo).stdout.strip():
                log("runs: nothing new to commit")
                return True
            git("-c", "user.name=github-actions[bot]",
                "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
                "commit", "-q", "-m", "%s-fetch: %s (run %s)" % (DISTRO, " ".join(packages)[:200], run), cwd=repo)
            r = git("push", "-q", "origin", "HEAD:runs", cwd=repo, check=False)
            if r.returncode == 0:
                log("runs: pushed %s" % target)
                return True
            log("runs: push refused (attempt %d), again on the new tip" % attempt)
        except RuntimeError as e:
            log("runs: %s (attempt %d)" % (e, attempt))
        finally:
            shutil.rmtree(work, ignore_errors=True)
        time.sleep(5 * attempt)
    warn("push to azsupport/azsupport (runs) failed")
    return False


def main():
    global SUITES, COMPONENTS, RUNS_DIR, DISTRO, DEFAULT
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", required=True)
    ap.add_argument("--report")
    ap.add_argument("--suites", default="")
    ap.add_argument("--distro", default="debian", choices=("debian", "ubuntu"))
    ap.add_argument("--push", action="store_true")
    ap.add_argument("packages", nargs="*")
    a = ap.parse_args()
    ubuntu = a.distro == "ubuntu"

    asked = []
    for item in " ".join(a.packages).replace(",", " ").split():
        name, _, version = item.partition("=")
        if not NAME.match(name) or (version and not VERSION.match(version)):
            warn("not a%s source package (or version): %r, left out" % ("n Ubuntu" if ubuntu else " Debian", item))
            continue
        if (name, version or None) not in asked:
            asked.append((name, version or None))
    if not asked:
        log("no packages")
        return 2
    if ubuntu:
        DISTRO, COMPONENTS, RUNS_DIR = "ubuntu", UBUNTU_COMPONENTS, UBUNTU_RUNS_DIR
        SUITES, DEFAULT = ubuntu_suites()
        if not SUITES:
            log("no release of Ubuntu found")
            return 1
    only = set(a.suites.replace(",", " ").split())
    unknown = only - {s[0] for s in SUITES}
    if unknown:
        warn("unknown suites, left out: %s" % " ".join(sorted(unknown)))
    suites = [s for s in SUITES if (s[0] in only if only else DEFAULT is None or s[0] in DEFAULT)]
    names = {n for n, _ in asked}

    # the indexes: the entries of the packages asked for (by source or binary name)
    found, read = {}, []
    prefetched = {}
    if ubuntu:
        # Ubuntu has several times as many suites (old-releases.ubuntu.com is slow): read
        # them in threads, used in their order below as before
        def read_suite(item):
            suite, candidates = item
            for base, dist in candidates:
                try:
                    got = read_index_filtered(base, dist, names)
                except Exception as e:  # noqa: BLE001
                    warn("%s %s: %s" % (suite, dist, e))
                    got = None
                if got is not None:
                    return suite, (got[0], got[1], base, dist)
            return suite, None
        with concurrent.futures.ThreadPoolExecutor(max_workers=UBUNTU_THREADS) as ex:
            prefetched = dict(ex.map(read_suite, [x for x in suites if x[0] != "sury"]))
    for suite, candidates in suites:
        if suite == "sury":
            continue
        stanzas = None
        for base, dist in candidates:
            try:
                if ubuntu:
                    got = prefetched.get(suite)
                    if got is not None and got[2:] != (base, dist):
                        continue
                    stanzas, total = (got[0], got[1]) if got is not None else (None, 0)
                else:
                    stanzas = read_index(base, dist)
                    total = len(stanzas) if stanzas is not None else 0
            except Exception as e:  # noqa: BLE001
                warn("%s %s: %s" % (suite, dist, e))
                stanzas = None
            if stanzas is not None:
                read.append((suite, "%s/dists/%s" % (base, dist), total))
                break
        if stanzas is None:
            read.append((suite, "not there", 0))
            continue
        for s in stanzas:
            pkg = s.get("Package", "")
            binaries = {b.strip() for b in s.get("Binary", "").replace("\n", " ").split(",")}
            for n in names:
                if pkg == n or n in binaries:
                    found.setdefault(n, []).append((suite, s))
        log("%s: %d sources" % (suite, read[-1][2]))

    os.makedirs(a.out, exist_ok=True)
    fetcher = Fetcher(a.out)
    pre = {}
    if ubuntu:
        # the versions of the suites, fetched in threads; the loop below takes them in its order
        jobs = {}
        for name, version in asked:
            hits = found.get(name, [])
            for suite, s in ([(su, s) for su, s in hits if s.get("Package") == name] or hits):
                jobs.setdefault((s.get("Package"), suite, s.get("Version")), (suite, s))

        def fetch_job(item):
            key, (suite, s) = item
            try:
                return key, from_suite(fetcher, key[0], suite, s), None
            except Exception as e:  # noqa: BLE001
                return key, None, e
        with concurrent.futures.ThreadPoolExecutor(max_workers=UBUNTU_THREADS) as ex:
            for key, res, err in ex.map(fetch_job, list(jobs.items())):
                pre[key] = (res, err)
    sury_read = [0]
    results, missing, errors = [], [], []
    order = {s[0]: i for i, s in enumerate(SUITES)}
    for name, version in asked:
        hits = found.get(name, [])
        exact = [(su, s) for su, s in hits if s.get("Package") == name]
        if not exact and hits:
            srcs = sorted({s.get("Package") for _, s in hits})
            warn("%s is no source package; its source: %s" % (name, " ".join(srcs)))
        use = exact or hits
        use.sort(key=lambda x: (order[x[0]], x[1].get("Package", "")))
        seen = set()
        for suite, s in use:
            src = s.get("Package")
            key = (src, suite, s.get("Version"))
            if key in seen:
                continue
            seen.add(key)
            try:
                if key in pre:
                    res, err = pre[key]
                    if err is not None:
                        raise err
                    v, fmt, dest = res
                else:
                    v, fmt, dest = from_suite(fetcher, src, suite, s)
                results.append((name, src, suite, v, fmt, os.path.relpath(dest, a.out)))
            except Exception as e:  # noqa: BLE001
                errors.append("%s %s %s: %s" % (src, suite, s.get("Version"), e))
        in_sury = False
        if not version and any(su[0] == "sury" for su in suites):
            try:
                pubs = sury_sources(name)
            except Exception as e:  # noqa: BLE001
                pubs = []
                errors.append("%s (sury): %s" % (name, e))
            for pub in pubs:
                try:
                    v, fmt, dest = from_sury(fetcher, name, pub)
                    results.append((name, name, "sury", v, fmt, os.path.relpath(dest, a.out)))
                    in_sury = True
                except Exception as e:  # noqa: BLE001
                    errors.append("%s %s (sury): %s" % (name, pub.get("source_package_version"), e))
            sury_read[0] += len(pubs)
        want = [version] if version else []
        if not use and not version:
            try:
                latest = launchpad_latest(name) if ubuntu else snapshot_latest(name)
            except Exception as e:  # noqa: BLE001
                latest = None
                errors.append("%s: %s: %s" % (name, "Launchpad" if ubuntu else "snapshot.debian.org", e))
            if latest:
                want.append(latest)
            elif not in_sury:
                missing.append(name)
        for v in want:
            try:
                if ubuntu:
                    v, fmt, dest = from_launchpad(fetcher, name, v)
                    results.append((name, name, "launchpad", v, fmt, os.path.relpath(dest, a.out)))
                    continue
                v, fmt, dest = from_snapshot(fetcher, name, v)
                results.append((name, name, "snapshot", v, fmt, os.path.relpath(dest, a.out)))
            except Exception as e:  # noqa: BLE001
                errors.append("%s %s (%s): %s" % (name, v, "Launchpad" if ubuntu else "snapshot", e))
    fetcher.close()
    if any(su[0] == "sury" for su in suites):
        read.append(("sury", "%s/%s (by name)" % (LAUNCHPAD, SURY_PPA), sury_read[0]))
    for e in errors:
        warn(e)

    day = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    pushed = None
    if a.push and results:
        pushed = push(a.out, day, [n if not v else "%s=%s" % (n, v) for n, v in asked],
                      os.environ.get("GITHUB_RUN_ID", "local"))

    rep = ["### %s fetch" % ("Ubuntu" if ubuntu else "Debian"), "",
           "Packages: `%s`; suites: %s." % (" ".join(n if not v else "%s=%s" % (n, v) for n, v in asked),
                                            " ".join(sorted(only)) if only else
                                            "the default ones" if ubuntu else "all"),
           ""]
    if pushed:
        rep += ["Pushed to the branch runs of azsupport/azsupport: `%s/%s/<package>/<suite>_<version>/`." % (
            RUNS_DIR, day), ""]
    elif a.push:
        rep += ["**Not pushed** to azsupport/azsupport (see the warnings).", ""]
    if ubuntu:
        rep += ["| asked | source | suite | version | format | date | directory |", "|---|---|---|---|---|---|---|"]
        for r in results:
            info = open(os.path.join(a.out, r[5], "source.txt")).read()
            m = re.search(r"^Date: (.+)$", info, re.M)
            esm = " (ESM after it)" if re.search(r"^Support: .* ESM ", info, re.M) else ""
            rep.append("| %s | %s | %s | %s | %s | %s%s | `%s` |" % (r[:5] + (m.group(1) if m else "?", esm, r[5])))
    else:
        rep += ["| asked | source | suite | version | format | directory |", "|---|---|---|---|---|---|"]
        rep += ["| %s | %s | %s | %s | %s | `%s` |" % r for r in results]
    if missing:
        rep += ["", "In no suite and not on %s: %s" % ("Launchpad" if ubuntu else "snapshot.debian.org",
                                                      ", ".join(missing))]
    if warnings:
        rep += ["", "Warnings:", ""] + ["- %s" % w for w in warnings]
    rep += ["", "<details><summary>Suites read</summary>", "", "| suite | index | sources |", "|---|---|---|"]
    rep += ["| %s | %s | %d |" % r for r in read]
    rep += ["", "</details>"]
    text = "\n".join(rep) + "\n"
    if a.report:
        with open(a.report, "w") as f:
            f.write(text)
    print(text)
    if not results:
        return 1
    return 0 if (pushed or not a.push) else 1


if __name__ == "__main__":
    sys.exit(main())
