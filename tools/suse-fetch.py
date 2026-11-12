#!/usr/bin/env python3
"""suse-fetch.py - the patches openSUSE and SUSE carry for source packages, in every release.

For each source package asked for (its openSUSE name: php7, libssh2_org, ImageMagick),
the version of every release that has it, from two kinds of source:

  repositories of download.opensuse.org: the source RPM of the newest version of the
  release (its GA repository and its update repositories together, a family):
    tumbleweed      source/tumbleweed/repo/oss
    leap-16.0       source/distribution/leap/16.0/repo/oss and its updates
    leap-15.6       source/distribution/leap/15.6/repo/oss, update/leap/15.6/oss,
                    update/leap/15.6/sle (SUSE Linux Enterprise 15 SP6), update/leap/15.6/backports
    leap-15.5 ... leap-15.0, leap-42.3
                    the same of the older releases (download.opensuse.org, or the
                    discontinued tree of a mirror)
  projects of the Open Build Service (api.opensuse.org/public, anonymous): the files of
  the package as the project has it, without the tarballs of upstream:
    factory         openSUSE:Factory; devel: the devel project Factory names for it
    sle-16.0-*      SUSE:SLFO:* (SUSE Linux Enterprise 16)
    sle-15-spN-update, sle-15-spN-ga, ... sle-12-update, sle-12-ga
                    SUSE:SLE-15-SPN:Update and :GA, every service pack of SLE 15 and 12
                    (a service pack ships what it does not rebuild from the ones before
                    it, so a package is often only in an older one; LTSS updates are
                    released there too, as far as they are public)
    backports-15-spN
                    openSUSE:Backports:SLE-15-SPN(:Update), Package Hub

Of every version: the spec files, the patches (the PatchN files of the spec, and any
*.patch, *.diff, *.dif), a tarball of patches (a name with "patch", up to OTHER_LIMIT),
the head of every .changes file (the entries of the last CHANGELOG_YEARS years, at least
CHANGELOG_MIN of them: it names the CVEs and bugs of each update), the list of all the
files with their sizes (files.txt) and source.txt (version, release, where from).

Layout of the output (--out DIR):

  DIR/<package>/<release>_<version>/
      source.txt  files.txt  <name>.spec  <name>.changes  patches/  other/

With --push the tree goes into the branch runs of azsupport/azsupport, under
distro/opensuse/<YYYY-MM-DD>/ (UTC), with an index.md per package, committed and
pushed with the token RUNS_TOKEN as tools/runs-report.sh does (a refused push is
made again on the new tip).

Exploring (the report says what it found): --search REGEX lists the source packages of
the repositories read and of openSUSE:Factory whose name matches; --explore URL lists
the entries of a directory of download.opensuse.org (or of the mirror) or of the OBS
API; --list-projects REGEX lists the OBS projects whose name matches.

Usage: python3 tools/suse-fetch.py --out DIR [--report FILE] [--releases LIST] [--push]
                                   [--obs LIST] [--search REGEX] [--explore URL...]
                                   [--list-projects REGEX] PACKAGE...
  --releases  only these releases (names as above, shell patterns: 'sle-15-*', 'leap-15.6')
  --obs       more OBS projects to read, as label=project (devel-php=devel:languages:php)
              or project (labelled obs-<project>)
"""

import argparse
import bz2
import concurrent.futures
import datetime
import fnmatch
import gzip
import hashlib
import io
import lzma
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

UA = "suse-fetch (azsupport/php-src)"
DL = "https://download.opensuse.org"
OLD = "https://ftp5.gwdg.de/pub/opensuse/discontinued"
OBS = "https://api.opensuse.org/public"
CHANGELOG_YEARS = 6
CHANGELOG_MIN = 10
CHANGELOG_MAX_LINES = 6000
FILE_LIMIT = 20 * 1024 * 1024        # a bigger patch is left out (named in files.txt)
OTHER_LIMIT = 5 * 1024 * 1024        # a tarball of patches up to this size is kept
RPM_LIMIT = 800 * 1024 * 1024        # a bigger source RPM is not downloaded
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+._-]*$")
PATCHY = re.compile(r"\.(patch|diff|dif)(\.(gz|bz2|xz|zst))?$", re.I)
RUNS_URL = "https://x-access-token:%s@github.com/azsupport/azsupport.git"
RUNS_DIR = "distro/opensuse"
ALLOWED = ("https://download.opensuse.org/", "https://ftp5.gwdg.de/pub/opensuse/",
           "https://api.opensuse.org/public/")


def leap(v):
    """The repositories of a Leap release: its GA source repository and its updates."""
    out = []
    for root in (DL, OLD):
        out.append(root + "/source/distribution/leap/%s/repo/oss" % v)
        parts = ("oss", "sle", "backports") if v >= "15.3" and not v.startswith("4") else ("oss",)
        for p in parts:
            out.append(root + "/update/leap/%s/%s" % (v, p))
    return out


# (release, [repository bases]): every repository found is read, and the newest version
# of a package in them is taken (GA, updates and the SLE packages of a Leap together).
REPOS = (
    ("tumbleweed", [DL + "/source/tumbleweed/repo/oss"]),
    ("leap-16.0", [DL + "/source/distribution/leap/16.0/repo/oss",
                   DL + "/distribution/leap/16.0/repo/src-oss",
                   DL + "/update/leap/16.0/oss", DL + "/update/leap/16.0/sle",
                   DL + "/update/leap/16.0/backports", DL + "/update/leap/16.0/repo/oss"]),
    ("leap-15.6", leap("15.6")),
    ("leap-15.5", leap("15.5")),
    ("leap-15.4", leap("15.4")),
    ("leap-15.3", leap("15.3")),
    ("leap-15.2", leap("15.2")),
    ("leap-15.1", leap("15.1")),
    ("leap-15.0", leap("15.0")),
    ("leap-42.3", leap("42.3")),
)


def sle_projects():
    """(release, [projects]): the first project of the list that has the package gives the
    version of the release (a service pack's :Update, else its :GA)."""
    out = [("sle-16.0", ["SUSE:SLFO:1.2:Update", "SUSE:SLFO:1.2"]), ("sle-16-main", ["SUSE:SLFO:Main"])]
    for sp in ("SP7", "SP6", "SP5", "SP4", "SP3", "SP2", "SP1", ""):
        base = "SUSE:SLE-15%s" % ("-" + sp if sp else "")
        out.append(("sle-15%s" % ("-" + sp.lower() if sp else ""), [base + ":Update", base + ":GA"]))
    for sp in ("SP5", "SP4", "SP3", "SP2", "SP1", ""):
        base = "SUSE:SLE-12%s" % ("-" + sp if sp else "")
        out.append(("sle-12%s" % ("-" + sp.lower() if sp else ""), [base + ":Update", base + ":GA"]))
    for sp in ("SP7", "SP6", "SP5", "SP4", "SP3"):
        out.append(("backports-15-%s" % sp.lower(), ["openSUSE:Backports:SLE-15-%s:Update" % sp,
                                                     "openSUSE:Backports:SLE-15-%s" % sp]))
    return out


# (release, [projects]): the projects of OBS read for every package ("devel" is found per
# package: the devel project of openSUSE:Factory).
PROJECTS = [("factory", ["openSUSE:Factory"])] + sle_projects()

warnings = []
lock = threading.Lock()


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def warn(msg):
    with lock:
        warnings.append(msg)
    print(("::warning title=suse-fetch::" if os.environ.get("GITHUB_ACTIONS") else "warning: ") + msg,
          file=sys.stderr, flush=True)


def request(url, tries=4, stream_to=None, limit=None):
    """GET url: its body (bytes), or with stream_to the number of bytes written to that
    file; None on 404/410 (not there)."""
    err = None
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=180) as r:
                if stream_to is None:
                    return r.read()
                n = 0
                with open(stream_to, "wb") as f:
                    while True:
                        chunk = r.read(1 << 20)
                        if not chunk:
                            break
                        n += len(chunk)
                        if limit and n > limit:
                            raise RuntimeError("bigger than %d bytes" % limit)
                        f.write(chunk)
                return n
        except urllib.error.HTTPError as e:
            if e.code in (404, 410):
                return None
            err = e
            if e.code in (401, 403):
                break
        except Exception as e:  # noqa: BLE001
            err = e
        if i + 1 < tries:
            time.sleep(4 * (i + 1))
    raise RuntimeError("%s: %s" % (url, err))


def unpack(raw, name):
    """A compressed repodata file, by its magic (or its name)."""
    if raw[:2] == b"\x1f\x8b":
        return gzip.decompress(raw)
    if raw[:6] == b"\xfd7zXZ\x00":
        return lzma.decompress(raw)
    if raw[:3] == b"BZh":
        return bz2.decompress(raw)
    if raw[:4] == b"\x28\xb5\x2f\xfd" or name.endswith(".zst"):
        r = subprocess.run(["zstd", "-dcq"], input=raw, capture_output=True)
        if r.returncode:
            raise RuntimeError("zstd: %s" % r.stderr.decode("utf-8", "replace").strip())
        return r.stdout
    return raw


# rpm's comparison of versions (rpmvercmp)
def rpmvercmp(a, b):
    if a == b:
        return 0
    sa = re.findall(r"~|\^|[0-9]+|[A-Za-z]+", a)
    sb = re.findall(r"~|\^|[0-9]+|[A-Za-z]+", b)
    while sa or sb:
        x = sa.pop(0) if sa else None
        y = sb.pop(0) if sb else None
        if x == "~" or y == "~":
            if x != y:
                return -1 if x == "~" else 1
            continue
        if x == "^" or y == "^":
            if x is None:
                return -1
            if y is None:
                return 1
            if x != y:
                return 1 if x == "^" else -1
            continue
        if x is None:
            return -1
        if y is None:
            return 1
        if x.isdigit() and y.isdigit():
            ix, iy = int(x), int(y)
            if ix != iy:
                return -1 if ix < iy else 1
        elif x.isdigit():
            return 1
        elif y.isdigit():
            return -1
        elif x != y:
            return -1 if x < y else 1
    return 0


def evr_cmp(a, b):
    """(epoch, version, release) tuples."""
    if int(a[0] or 0) != int(b[0] or 0):
        return -1 if int(a[0] or 0) < int(b[0] or 0) else 1
    return rpmvercmp(a[1], b[1]) or rpmvercmp(a[2], b[2])


# ------------------------------------------------------------------ repositories
NS_REPO = "{http://linux.duke.edu/metadata/repo}"
NS_COMMON = "{http://linux.duke.edu/metadata/common}"
XML_BASE = "{http://www.w3.org/XML/1998/namespace}base"


def read_repo(base, wanted, pattern):
    """The source packages of a repository (repodata): {name: [entry]} of the names
    wanted, and the names matching pattern (--search); None when it is not there."""
    raw = request(base + "/repodata/repomd.xml")
    if raw is None:
        return None
    root = ET.fromstring(raw)
    href = None
    for data in root.findall(NS_REPO + "data"):
        if data.get("type") == "primary":
            href = data.find(NS_REPO + "location").get("href")
    if not href:
        raise RuntimeError("%s: no primary in repomd.xml" % base)
    body = request(base + "/" + href)
    if body is None:
        raise RuntimeError("%s/%s: not found" % (base, href))
    xml = unpack(body, href)
    found, names, nsrc = {}, set(), 0
    for _, el in ET.iterparse(io.BytesIO(xml), events=("end",)):
        if el.tag != NS_COMMON + "package":
            continue
        arch = el.findtext(NS_COMMON + "arch")
        if arch not in ("src", "nosrc"):
            el.clear()
            continue
        nsrc += 1
        name = el.findtext(NS_COMMON + "name")
        if pattern and pattern.search(name):
            names.add(name)
        if name in wanted:
            v = el.find(NS_COMMON + "version")
            loc = el.find(NS_COMMON + "location")
            size = el.find(NS_COMMON + "size")
            ck = el.find(NS_COMMON + "checksum")
            found.setdefault(name, []).append({
                "name": name, "epoch": v.get("epoch") or "0", "ver": v.get("ver"), "rel": v.get("rel"),
                "url": (loc.get(XML_BASE) or base).rstrip("/") + "/" + loc.get("href"),
                "size": int(size.get("package") or 0) if size is not None else 0,
                "sum": (ck.get("type"), ck.text) if ck is not None else (None, None),
                "repo": base})
        el.clear()
    return found, names, nsrc


# ------------------------------------------------------------------ source RPMs
def rpm_header(f, pad):
    h = f.read(16)
    if len(h) != 16 or h[:3] != b"\x8e\xad\xe8":
        raise RuntimeError("not an rpm header")
    nindex, hsize = struct.unpack(">II", h[8:16])
    index = f.read(16 * nindex)
    store = f.read(hsize)
    if pad:
        f.read((8 - (16 + 16 * nindex + hsize) % 8) % 8)
    tags = {}
    for i in range(nindex):
        tag, typ, off, cnt = struct.unpack(">IIII", index[16 * i:16 * i + 16])
        tags[tag] = (typ, off, cnt)
    return tags, store


def rpm_strings(hdr, tag):
    tags, store = hdr
    if tag not in tags:
        return []
    typ, off, cnt = tags[tag]
    if typ not in (6, 8, 9):
        return []
    out = []
    for _ in range(cnt if typ != 6 else 1):
        end = store.index(b"\0", off)
        out.append(store[off:end].decode("utf-8", "replace"))
        off = end + 1
    return out


def read_exact(stream, n):
    out = bytearray()
    while len(out) < n:
        chunk = stream.read(n - len(out))
        if not chunk:
            raise RuntimeError("payload cut short")
        out += chunk
    return bytes(out)


def rpm_unpack(path, keep):
    """The files of a source RPM: (header info, [(name, size, sha256, data or None)]);
    keep(name, size, patches) says which files to read into memory."""
    with open(path, "rb") as f:
        lead = f.read(96)
        if lead[:4] != b"\xed\xab\xee\xdb":
            raise RuntimeError("not an rpm")
        rpm_header(f, True)
        hdr = rpm_header(f, False)
        off = f.tell()
        magic = f.read(6)
    info = {"name": (rpm_strings(hdr, 1000) or ["?"])[0], "version": (rpm_strings(hdr, 1001) or ["?"])[0],
            "release": (rpm_strings(hdr, 1002) or ["?"])[0], "patches": rpm_strings(hdr, 1019),
            "sources": rpm_strings(hdr, 1018)}
    fd = os.open(path, os.O_RDONLY)
    os.lseek(fd, off, 0)
    proc, raw = None, os.fdopen(fd, "rb")
    try:
        if magic[:2] == b"\x1f\x8b":
            stream = gzip.GzipFile(fileobj=raw)
        elif magic[:6] == b"\xfd7zXZ\x00" or magic[:3] == b"\x5d\x00\x00":
            stream = lzma.LZMAFile(raw)
        elif magic[:3] == b"BZh":
            stream = bz2.BZ2File(raw)
        elif magic[:4] == b"\x28\xb5\x2f\xfd":
            proc = subprocess.Popen(["zstd", "-dcq"], stdin=raw, stdout=subprocess.PIPE)
            stream = proc.stdout
        elif magic[:6] in (b"070701", b"070702"):
            stream = raw
        else:
            raise RuntimeError("unknown payload compression %r" % magic)
        files = []
        pos = 0
        while True:
            h = read_exact(stream, 110)
            pos += 110
            if h[:6] not in (b"070701", b"070702"):
                raise RuntimeError("bad cpio header at %d" % pos)
            fields = [int(h[6 + 8 * i:14 + 8 * i], 16) for i in range(13)]
            mode, size, namesize = fields[1], fields[6], fields[11]
            name = read_exact(stream, namesize)[:-1].decode("utf-8", "replace")
            pos += namesize
            read_exact(stream, (4 - pos % 4) % 4)
            pos += (4 - pos % 4) % 4
            if name == "TRAILER!!!":
                break
            name = name[2:] if name.startswith("./") else name
            want = (mode & 0o170000) == 0o100000 and keep(name, size, info["patches"])
            sha = hashlib.sha256()
            data = bytearray() if want else None
            left = size
            while left:
                chunk = stream.read(min(left, 1 << 20))
                if not chunk:
                    raise RuntimeError("payload cut short in %s" % name)
                sha.update(chunk)
                if want:
                    data += chunk
                left -= len(chunk)
            pos += size
            read_exact(stream, (4 - pos % 4) % 4)
            pos += (4 - pos % 4) % 4
            files.append((name, size, sha.hexdigest(), bytes(data) if want else None))
        return info, files
    finally:
        if proc:
            proc.stdout.close()
            proc.kill()
            proc.wait()
        raw.close()


# ------------------------------------------------------------------ OBS
_projects = {}


def obs(path, params=None):
    url = "%s/%s" % (OBS, path)
    if params:
        url += "?" + urllib.parse.urlencode(params)
    return request(url)


def obs_packages(project):
    """The packages of a project of OBS (a set), None when it is not there."""
    with lock:
        if project in _projects:
            return _projects[project]
    try:
        raw = obs("source/%s" % urllib.parse.quote(project, safe=":"))
        names = None if raw is None else {e.get("name") for e in ET.fromstring(raw).findall("entry")}
    except Exception as e:  # noqa: BLE001
        warn("OBS %s: %s" % (project, e))
        names = None
    with lock:
        _projects[project] = names
    return names


def obs_pick(names, pkg):
    """The package of a project for pkg: pkg itself, or its newest maintenance incident
    (pkg.NNNNN) when the project has no pkg."""
    if pkg in names:
        return pkg
    inc = [n for n in names if n.startswith(pkg + ".") and n[len(pkg) + 1:].isdigit()]
    return max(inc, key=lambda n: int(n.rsplit(".", 1)[1])) if inc else None


def obs_listing(project, package):
    q = urllib.parse.quote
    path = "source/%s/%s" % (q(project, safe=":"), q(package, safe=""))
    raw = None
    for params in ({"expand": "1"}, None):
        try:
            raw = obs(path, params)
        except RuntimeError as e:
            if params is None:
                raise
            log("%s/%s: %s (unexpanded instead)" % (project, package, e))
            continue
        if raw is not None:
            break
    if raw is None:
        return None
    d = ET.fromstring(raw)
    entries = [(e.get("name"), int(e.get("size") or 0), e.get("md5")) for e in d.findall("entry")]
    li = d.find("linkinfo")
    link = None
    if li is not None:
        link = "%s/%s" % (li.get("project") or project, li.get("package") or package)
    return {"rev": d.get("rev"), "srcmd5": d.get("srcmd5"), "entries": entries, "link": link,
            "expanded": d.get("srcmd5")}


_files = {}


def obs_file(project, package, name, rev, md5=None):
    with lock:
        if md5 and md5 in _files:
            return _files[md5]
    raw = _obs_file(project, package, name, rev)
    if md5 and hashlib.md5(raw).hexdigest() == md5:
        with lock:
            _files[md5] = raw
    return raw


def _obs_file(project, package, name, rev):
    q = urllib.parse.quote
    path = "source/%s/%s/%s" % (q(project, safe=":"), q(package, safe=""), q(name, safe=""))
    for params in ({"rev": rev} if rev else None, {"expand": "1"}, None):
        try:
            raw = obs(path, params)
        except RuntimeError:
            continue
        if raw is not None:
            return raw
    raise RuntimeError("%s/%s/%s: not readable" % (project, package, name))


def obs_devel(package):
    """The devel project of a package of openSUSE:Factory: (project, package) or None."""
    try:
        raw = obs("source/openSUSE:Factory/%s/_meta" % urllib.parse.quote(package, safe=""))
    except RuntimeError as e:
        warn("OBS openSUSE:Factory/%s/_meta: %s" % (package, e))
        return None
    if raw is None:
        return None
    d = ET.fromstring(raw).find("devel")
    if d is None or not d.get("project"):
        return None
    return d.get("project"), d.get("package") or package


# ------------------------------------------------------------------ specs and .changes
def spec_macros(text):
    macros = {}
    for line in text.splitlines():
        m = re.match(r"\s*%(?:define|global)\s+(\w+)\s+(.*?)\s*$", line)
        if m and m.group(1) not in macros:
            macros[m.group(1)] = m.group(2)
        m = re.match(r"(?i)\s*(Name|Version|Release)\s*:\s*(\S+)", line)
        if m and m.group(1).lower() not in macros:
            macros[m.group(1).lower()] = m.group(2)
    return macros


def expand(s, macros):
    for _ in range(12):
        new = re.sub(r"%\{\??(\w+)\}|%(\w+)",
                     lambda m: macros.get(m.group(1) or m.group(2), m.group(0)), s)
        if new == s:
            break
        s = new
    return s


def spec_info(text):
    """(version, [patch file names]) of a spec, its macros expanded as far as they go."""
    macros = spec_macros(text)
    version = expand(macros.get("version", "?"), macros)
    patches = []
    for line in text.splitlines():
        m = re.match(r"(?i)\s*Patch\d*\s*:\s*(\S+)", line)
        if m:
            patches.append(os.path.basename(expand(m.group(1), macros)))
    return version, patches


SEP = re.compile(r"^-{20,}\s*$")


def changes_head(text):
    """The newest entries of a .changes: CHANGELOG_YEARS years, at least CHANGELOG_MIN."""
    cutoff = datetime.date.today().replace(year=datetime.date.today().year - CHANGELOG_YEARS)
    lines = text.splitlines()
    out, n, i = [], 0, 0
    while i < len(lines):
        if SEP.match(lines[i]) and i + 1 < len(lines):
            n += 1
            m = re.search(r"\b(\d{4})\b", lines[i + 1])
            m2 = re.search(r"([A-Z][a-z]{2})\s+(\d{1,2})\s.*?(\d{4})", lines[i + 1])
            day = None
            if m2:
                try:
                    day = datetime.datetime.strptime("%s %s %s" % (m2.group(1), m2.group(2), m2.group(3)),
                                                     "%b %d %Y").date()
                except ValueError:
                    day = None
            if day is None and m:
                day = datetime.date(int(m.group(1)), 1, 1)
            if n > CHANGELOG_MIN and day is not None and day < cutoff:
                out.append("... (older entries cut: %d years, at least %d entries)" % (CHANGELOG_YEARS, CHANGELOG_MIN))
                break
        out.append(lines[i])
        if len(out) >= CHANGELOG_MAX_LINES:
            out.append("... (cut at %d lines)" % CHANGELOG_MAX_LINES)
            break
        i += 1
    return ("\n".join(out).rstrip() + "\n").encode("utf-8")


def safe(path):
    parts = [p for p in path.split("/") if p not in ("", ".")]
    if not parts or any(p == ".." for p in parts):
        return None
    return "/".join(parts)


def kind(name, size, patches):
    """Where a file of a package goes: spec, changes, patch, other, or None (listed only)."""
    base = os.path.basename(name)
    if base.endswith(".spec"):
        return "spec"
    if base.endswith(".changes"):
        return "changes"
    if base in patches or PATCHY.search(base) or base == "series":
        return "patch" if size <= FILE_LIMIT else None
    if "patch" in base.lower() and size <= OTHER_LIMIT:
        return "other"
    return None


def write_version(dest, files, info_lines, patches=()):
    """files: [(name, size, sha256 or md5, data or None)]; patches: the names of the
    patches the package declares (the PATCH tag of a source RPM)."""
    if os.path.exists(dest):
        shutil.rmtree(dest)
    os.makedirs(dest)
    patches = set(patches)
    for name, size, ck, data in files:
        if data is not None and kind(name, size, ()) == "spec":
            patches.update(spec_info(data.decode("utf-8", "replace"))[1])
    listing, npatch = [], 0
    for name, size, ck, data in sorted(files):
        rel = safe(name)
        k = kind(name, size, patches) if rel else None
        note = ""
        if k and data is None:
            note = " (not read)"
        listing.append("%s %d %s%s" % (name, size, ck or "-", note))
        if not k or data is None:
            continue
        base = os.path.basename(rel)
        if k == "spec":
            target = base
        elif k == "changes":
            target, data = base, changes_head(data.decode("utf-8", "replace"))
        elif k == "patch":
            target = "patches/" + base
            npatch += 1
        else:
            target = "other/" + base
        path = os.path.join(dest, target)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data)
    with open(os.path.join(dest, "files.txt"), "w") as f:
        f.write("".join("%s\n" % x for x in listing))
    with open(os.path.join(dest, "source.txt"), "w") as f:
        f.write("\n".join(info_lines + ["Patches: %d" % npatch]) + "\n")
    return npatch


def dirname(release, version):
    if "%" in version:          # a macro of the spec left unexpanded: the part before it
        version = version.split("%", 1)[0].rstrip(".-_") or "unknown"
    return "%s_%s" % (release, re.sub(r"[^A-Za-z0-9.+~_-]", "_", version))


# ------------------------------------------------------------------ fetching
class Fetcher:
    def __init__(self, out):
        self.out = out
        self.tmp = tempfile.mkdtemp(prefix="suse-fetch-")
        self.rpms = {}          # url -> (info, files)
        self.obsdone = {}       # (project, package, srcmd5) -> (version, files)
        self.rlock = threading.Lock()

    def close(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def rpm(self, e):
        with self.rlock:
            if e["url"] in self.rpms:
                return self.rpms[e["url"]]
        if e["size"] and e["size"] > RPM_LIMIT:
            raise RuntimeError("%s: %d bytes, bigger than %d: not downloaded" % (e["url"], e["size"], RPM_LIMIT))
        path = os.path.join(self.tmp, "%s-%s.src.rpm" % (threading.get_ident(), e["name"]))
        try:
            n = request(e["url"], stream_to=path, limit=RPM_LIMIT)
            if n is None:
                raise RuntimeError("%s: not found" % e["url"])
            typ, want = e["sum"]
            if typ in ("sha256", "sha512", "sha1") and want:
                h = hashlib.new(typ)
                with open(path, "rb") as f:
                    for chunk in iter(lambda: f.read(1 << 20), b""):
                        h.update(chunk)
                if h.hexdigest() != want:
                    raise RuntimeError("%s: %s differs from the repository's" % (e["url"], typ))
            res = rpm_unpack(path, lambda name, size, patches: kind(name, size, patches) is not None)
        finally:
            if os.path.exists(path):
                os.remove(path)
        with self.rlock:
            self.rpms[e["url"]] = res
        return res

    def from_repo(self, pkg, release, entries):
        best = None
        for e in entries:
            if best is None or evr_cmp((e["epoch"], e["ver"], e["rel"]), (best["epoch"], best["ver"], best["rel"])) > 0:
                best = e
        info, files = self.rpm(best)
        version = "%s-%s" % (best["ver"], best["rel"])
        dest = os.path.join(self.out, pkg, dirname(release, version))
        others = sorted({"%s %s-%s" % (x["repo"], x["ver"], x["rel"]) for x in entries if x is not best})
        lines = ["Package: %s" % pkg, "Version: %s" % version, "Release: %s" % release,
                 "From: %s" % best["url"], "Repository: %s" % best["repo"],
                 "Checksum: %s %s" % best["sum"]]
        lines += ["Also in: %s" % o for o in others]
        n = write_version(dest, files, lines, info["patches"])
        return version, dest, n

    def from_obs(self, pkg, release, project, package):
        lst = obs_listing(project, package)
        if lst is None:
            raise RuntimeError("%s/%s: no listing" % (project, package))
        key = lst["srcmd5"]
        with self.rlock:
            hit = self.obsdone.get(key)
        if hit is None:
            files, specs = [], {}
            rev = lst["srcmd5"]
            names = [n for n, _, _ in lst["entries"]]
            for name, size, md5 in lst["entries"]:
                if name.endswith(".spec"):
                    specs[name] = obs_file(project, package, name, rev, md5)
            patches = set()
            version = None
            for name, data in sorted(specs.items(), key=lambda x: (x[0] != pkg + ".spec", x[0])):
                v, p = spec_info(data.decode("utf-8", "replace"))
                patches.update(p)
                if version is None:
                    version = v
            for name, size, md5 in lst["entries"]:
                k = kind(name, size, patches)
                data = specs.get(name)
                if k and data is None:
                    try:
                        data = obs_file(project, package, name, rev, md5)
                    except RuntimeError as e:
                        warn(str(e))
                files.append((name, size, "md5:" + (md5 or "-"), data))
            missing = sorted(p for p in patches if p not in names)
            hit = (version or "unknown", files, patches, missing)
            with self.rlock:
                self.obsdone[key] = hit
        version, files, patches, missing = hit
        dest = os.path.join(self.out, pkg, dirname(release, version))
        lines = ["Package: %s" % pkg, "Version: %s" % version, "Release: %s" % release,
                 "From: %s/source/%s/%s (OBS, srcmd5 %s, rev %s)" % (OBS, project, package, lst["srcmd5"], lst["rev"]),
                 "Project: %s" % project, "OBS package: %s" % package]
        if lst["link"]:
            lines.append("Link: %s" % lst["link"])
        if missing:
            lines.append("Patch lines of the spec without a file (macros not expanded): %s" % " ".join(missing))
        n = write_version(dest, files, lines, patches)
        return version, dest, n


def index_md(pkgdir, pkg, day):
    rows = []
    for d in sorted(os.listdir(pkgdir)):
        p = os.path.join(pkgdir, d, "source.txt")
        if not os.path.isfile(p):
            continue
        info = dict(line.split(": ", 1) for line in open(p).read().splitlines() if ": " in line)
        rows.append((info.get("Release", "?"), info.get("Version", "?"), info.get("Patches", "?"),
                     info.get("Project") or info.get("Repository", "?"), d))
    order = {r: i for i, r in enumerate([r for r, _ in REPOS] + ["factory", "devel"] + [r for r, _ in PROJECTS])}
    rows.sort(key=lambda r: (order.get(r[0], len(order)), r[0]))
    lines = ["# %s: openSUSE and SUSE, %s" % (pkg, day), "",
             "Written by tools/suse-fetch.py of azsupport/php-src (workflow suse-fetch.yml).", "",
             "| release | version | patches | from | directory |", "|---|---|---|---|---|"]
    lines += ["| %s | %s | %s | %s | [%s](%s/) |" % (r[0], r[1], r[2], r[3], r[4], r[4]) for r in rows]
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

    for attempt in range(1, 8):
        work = tempfile.mkdtemp()
        try:
            repo = os.path.join(work, "r")
            git("clone", "-q", "--depth", "1", "--filter=blob:none", "--sparse", "--branch", "runs",
                "--single-branch", remote, repo)
            git("sparse-checkout", "set", target, cwd=repo)
            for pkg in sorted(os.listdir(out)):
                dst = os.path.join(repo, target, pkg)
                for d in sorted(os.listdir(os.path.join(out, pkg))):
                    if os.path.exists(os.path.join(dst, d)):
                        shutil.rmtree(os.path.join(dst, d))
                    shutil.copytree(os.path.join(out, pkg, d), os.path.join(dst, d))
                index_md(dst, pkg, day)
            git("add", "-A", target, cwd=repo)
            if not git("status", "--porcelain", cwd=repo).stdout.strip():
                log("runs: nothing new to commit")
                return True
            git("-c", "user.name=github-actions[bot]",
                "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
                "commit", "-q", "-m", "suse-fetch: %s (run %s)" % (" ".join(packages)[:200], run), cwd=repo)
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


def explore(url):
    """The entries of a directory listing (download.opensuse.org, the mirror) or of an
    XML listing of OBS: [names]."""
    if not url.startswith(ALLOWED):
        return ["(not an address of openSUSE: left out)"]
    raw = request(url)
    if raw is None:
        return ["(not found)"]
    text = raw.decode("utf-8", "replace")
    if text.lstrip().startswith("<directory") or text.lstrip().startswith("<?xml"):
        try:
            d = ET.fromstring(raw)
            return ["%s %s" % (e.get("name"), e.get("size") or "") for e in d.iter("entry")] or [text[:2000]]
        except ET.ParseError:
            return [text[:2000]]
    path = urllib.parse.urlparse(url).path
    names = []
    for href in re.findall(r'href="([^"#]+)"', text):
        h = urllib.parse.unquote(href)
        if h.startswith(("http://", "https://")):
            h = urllib.parse.urlparse(h).path
        if h.startswith("/"):
            if not h.startswith(path) or h == path:
                continue
            h = h[len(path):].lstrip("/")
        if not h or h.startswith(("..", "?")):
            continue
        if h not in names:
            names.append(h)
    return names or [text[:1500]]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", required=True)
    ap.add_argument("--report")
    ap.add_argument("--releases", default="")
    ap.add_argument("--push", action="store_true")
    ap.add_argument("--search", default="")
    ap.add_argument("--explore", default="")
    ap.add_argument("--list-projects", default="")
    ap.add_argument("--obs", default="")
    ap.add_argument("--jobs", type=int, default=10)
    ap.add_argument("packages", nargs="*")
    a = ap.parse_args()

    asked = []
    for item in " ".join(a.packages).replace(",", " ").split():
        if not NAME.match(item):
            warn("not a source package name: %r, left out" % item)
            continue
        if item not in asked:
            asked.append(item)
    pats = a.releases.replace(",", " ").split()

    def chosen(label):
        return not pats or any(fnmatch.fnmatch(label, p) for p in pats)

    search = re.compile(a.search) if a.search else None
    rep = ["### openSUSE and SUSE fetch", "",
           "Packages: `%s`; releases: %s." % (" ".join(asked) or "-", " ".join(pats) or "all"), ""]

    # the repositories
    repo_hits, read, matches = {}, [], {}
    done_paths = set()
    for release, bases in REPOS:
        if not chosen(release):
            continue
        for base in bases:
            path = base.replace(OLD, "").replace(DL, "")
            if path in done_paths:          # the discontinued tree of a mirror: only what is gone
                continue
            try:
                res = read_repo(base, set(asked), search)
            except Exception as e:  # noqa: BLE001
                read.append((release, base, "error: %s" % e))
                continue
            if res is None:
                read.append((release, base, "not there"))
                continue
            found, names, nsrc = res
            done_paths.add(path)
            read.append((release, base, "%d source packages" % nsrc))
            for n, entries in found.items():
                repo_hits.setdefault((n, release), []).extend(entries)
            if names:
                matches.setdefault(release, set()).update(names)
            log("%s %s: %d source packages" % (release, base, nsrc))

    # the projects of OBS
    for item in a.obs.replace(",", " ").split():
        label, _, project = item.partition("=")
        if not project:
            label, project = "obs-" + re.sub(r"[^A-Za-z0-9.-]+", "-", item).lower(), item
        if re.match(r"^[A-Za-z0-9][A-Za-z0-9:._-]*$", project) and re.match(r"^[a-z0-9][a-z0-9.-]*$", label):
            PROJECTS.append((label, [project]))
        else:
            warn("not an OBS project: %r, left out" % item)
    projects = [(r, ps) for r, ps in PROJECTS if chosen(r)]
    obs_read = []
    seen_prj = set()
    for release, plist in projects:
        for project in plist:
            if project in seen_prj:
                continue
            seen_prj.add(project)
            names = obs_packages(project)
            obs_read.append((release, project, "not readable" if names is None else "%d packages" % len(names)))
            log("%s %s: %s" % (release, project, obs_read[-1][2]))
            if search and names and release == "factory":
                matches.setdefault("factory", set()).update(n for n in names if search.search(n) and "." not in n)

    os.makedirs(a.out, exist_ok=True)
    fetcher = Fetcher(a.out)
    tasks = []
    for pkg in asked:
        for release, _ in REPOS:
            if (pkg, release) in repo_hits:
                tasks.append(("repo", pkg, release, repo_hits[(pkg, release)]))
        for release, plist in projects:
            for project in plist:
                names = _projects.get(project)
                p = obs_pick(names, pkg) if names else None
                if p:
                    tasks.append(("obs", pkg, release, (project, p)))
                    break
        if chosen("devel"):
            dv = obs_devel(pkg)
            if dv:
                tasks.append(("obs", pkg, "devel", dv))

    results, errors = [], []

    def run(t):
        how, pkg, release, what = t
        try:
            if how == "repo":
                v, dest, n = fetcher.from_repo(pkg, release, what)
                src = what[0]["repo"]
            else:
                v, dest, n = fetcher.from_obs(pkg, release, what[0], what[1])
                src = "%s/%s" % what
            return ("ok", pkg, release, v, n, src, os.path.relpath(dest, a.out))
        except Exception as e:  # noqa: BLE001
            return ("error", pkg, release, "%s: %s" % (how, e))

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, a.jobs)) as ex:
        for r in ex.map(run, tasks):
            if r[0] == "ok":
                results.append(r[1:])
                log("%s %s: %s (%d patches)" % (r[1], r[2], r[3], r[4]))
            else:
                errors.append("%s %s: %s" % r[1:])
    fetcher.close()
    for e in errors:
        warn(e)

    day = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    pushed = None
    if a.push and results:
        pushed = push(a.out, day, asked, os.environ.get("GITHUB_RUN_ID", "local"))
    if pushed:
        rep += ["Pushed to the branch runs of azsupport/azsupport: `%s/%s/<package>/<release>_<version>/`." % (
            RUNS_DIR, day), ""]
    elif a.push and results:
        rep += ["**Not pushed** to azsupport/azsupport (see the warnings).", ""]
    if asked:
        rep += ["| package | release | version | patches | from | directory |", "|---|---|---|---|---|---|"]
        order = {r: i for i, r in enumerate([r for r, _ in REPOS] + ["factory", "devel"] + [r for r, _ in PROJECTS])}
        results.sort(key=lambda r: (asked.index(r[0]), order.get(r[1], 999)))
        rep += ["| %s | %s | %s | %d | %s | `%s` |" % r for r in results]
        none = [p for p in asked if not any(r[0] == p for r in results)]
        if none:
            rep += ["", "Found nowhere: %s" % ", ".join(none)]
    if warnings:
        rep += ["", "Warnings:", ""] + ["- %s" % w for w in warnings]
    if search:
        rep += ["", "Search `%s`:" % a.search, ""]
        for release in sorted(matches):
            rep.append("- %s: %s" % (release, " ".join(sorted(matches[release]))))
            log("search %s: %s" % (release, " ".join(sorted(matches[release]))))
    if a.list_projects:
        rep += ["", "Projects of OBS matching `%s`:" % a.list_projects, ""]
        try:
            raw = obs("source")
            pr = re.compile(a.list_projects)
            names = sorted(e.get("name") for e in ET.fromstring(raw).findall("entry") if pr.search(e.get("name")))
            rep.append(" ".join(names) if names else "(none)")
        except Exception as e:  # noqa: BLE001
            rep.append("(OBS project list not readable: %s)" % e)
    for url in a.explore.split():
        rep += ["", "Explore %s:" % url, "", "```"]
        try:
            rep += explore(url)[:400]
        except Exception as e:  # noqa: BLE001
            rep.append("(error: %s)" % e)
        rep.append("```")
    rep += ["", "<details><summary>Repositories and projects read</summary>", "",
            "| release | repository or project | read |", "|---|---|---|"]
    rep += ["| %s | %s | %s |" % r for r in read + obs_read]
    rep += ["", "</details>"]
    text = "\n".join(rep) + "\n"
    if a.report:
        with open(a.report, "w") as f:
            f.write(text)
    print(text)
    if asked and not results:
        return 1
    return 0 if (pushed or not a.push or not results) else 1


if __name__ == "__main__":
    sys.exit(main())
