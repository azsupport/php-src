#!/usr/bin/env python3
"""upstream-check.py - what the upstreams of this fork published since we looked.

Releases. For every extension in freebsd/pecl.conf: the release tags of its
repository and its PECL releases; for curl (freebsd/curl.conf) the tags of
github.com/curl/curl; for the libraries of the bundled curl
(freebsd/curl-deps.conf) the tags of their repositories; for PCRE2
(freebsd/pcre.conf) the tags of github.com/PCRE2Project/pcre2 (PCRE 8.45 of 5.6
is the last PCRE1 release). A
stable release newer than the bundled one
is reported for the targets whose PHP version it supports (package.xml of the
tag, else the PECL dependencies). A "pin" line in freebsd/upstream.conf keeps
an extension to one series. Pre-releases count only where the bundled version
is one (gmagick, memcache 3.0.8).

FreeBSD ports. For every "port" line in freebsd/upstream.conf and for
lang/<port> of freebsd/targets.conf (at its portrev): the freebsd-ports commits
after the reviewed revision that change files/ (the patches) or the Makefile
beyond its version lines, or that move the port away. For curl and the libraries
of freebsd/curl-deps.conf also the distinfo of their port: a release file there
that differs from the bundled one (the port took a new release, the public
suffix list a new date) - not while the bundle is ahead of the port (a release
taken before its port for a security fix).

The rule (04.11.2026): a new release is taken when its FreeBSD port has it;
before the port only when it fixes a vulnerability that touches us, or a bug we
have. So a release issue says what the release notes name (CVE and GHSA ids, on
GitHub) and what the commit messages since the tag of the version built name (any
git repository), and it stays open as a note until the port has the version.

The libraries of /usr/local/az built from ports (static in /usr/local/az/static,
shared in /usr/local/az/lib), and the packages built against them (FFmpeg,
ImageMagick): the ports of azsupport/ports build them (since 08.11.2026), each from
a conf file of its own there (PORTS_CONF: az/az/files/deps.conf,
multimedia/ffmpeg/files/ffmpeg.conf, graphics/ImageMagick7/files/imagemagick.conf),
which this check reads from a checkout of azsupport/ports (--ports, default
ports/ of this checkout: the workflow checks it out there):
their upstream releases ("upstream" lines: tags or a directory listing) newer than
the version built (taken before the port only for a security fix: "take" lines);
the commits to their ports after the ports commit of the conf file; and a port
that has caught up with a take line, which can go then.

Other distributions (aZ, 11.11.2026: the FreeBSD tree lacked fixes that they
carry), each row of freebsd/upstream.conf with the date of its last review:
"gentoo" and "openbsd" lines, the commits of gentoo/gentoo or openbsd/ports to a
directory after that date (their patches); "debian" lines, the advisories of
Debian (DSA, DLA) and of Freexian's Extended LTS (ELA) for a source package and,
with "uploads", its uploads to unstable; "sury" and "ubuntu" lines, the uploads
of a package to the PPA of Ondrej Sury or to Ubuntu, with their changelog (the
fixes of the PHP branches out of upstream support); for a "cve" line the CVEs of
NVD that name a library without an upstream (t1lib), published after its date.

PHP branches. For the targets that follow the php-src release tags: the end of
security support of the branch (php.net/releases/branches.php), from 60 days
before it on, with whether Remi Collet's php-src-security has a
PHP-X.Y-security-backports branch to switch to.

Every finding is one issue with the labels "upstream" and "release", "ports" or "eol",
marked in its body, so the next runs update that issue instead of opening
another one. An open issue whose finding is gone (pecl.conf has the version,
the reviewed revision moved on) is closed; a closed one stays closed, so
closing an issue is how to say "not wanted". Nothing is applied.

Usage: python3 tools/upstream-check.py [--dry-run] [--repo OWNER/NAME]
                                       [--workdir DIR] [--days N] [--ports DIR]
  --dry-run   print the findings, do not read or change issues
  --repo      repository of the issues (default: $GITHUB_REPOSITORY)
  --workdir   where the git clones go (default: a temporary directory)
  --days      freebsd-ports history to fetch (default 180); a reviewed revision
              older than that is reported, with all commits of these days
  --ports     a checkout of azsupport/ports, for the conf files of the bundles
              (default: ports/ of this checkout); without them az, FFmpeg and
              ImageMagick are not checked, and their issues stay as they are
"""

import argparse
import datetime
import email.utils
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORTS_URL = "https://github.com/freebsd/freebsd-ports"
PECL_REST = "https://pecl.php.net/rest/r"
PHP_BRANCHES = "https://www.php.net/releases/branches.php"
REMI_SECURITY = "https://github.com/remicollet/php-src-security"
EOL_NOTICE_DAYS = 60
MARK = "<!-- upstream-check: %s -->"
STAGE = {"alpha": 0, "a": 0, "beta": 1, "b": 1, "rc": 2}
# Makefile lines of a port that only follow a new release (or a new PHP flavor).
VERSION_LINE = re.compile(
    r"^[-+]\s*(#.*)?$|^[-+]\s*(PORTVERSION|DISTVERSION|DISTVERSIONPREFIX|"
    r"DISTVERSIONSUFFIX|PORTREVISION|PORTEPOCH|MAINTAINER|WWW|COMMENT|"
    r"GH_TAGNAME|IGNORE_WITH_PHP)\s*[?:+]?=")
BODY_LIMIT = 60000


def log(msg):
    print(msg, file=sys.stderr)


def warn(msg):
    # An annotation on the run page when this runs in GitHub Actions.
    print(("::warning::" if os.environ.get("GITHUB_ACTIONS") else "warning: ") + msg,
          file=sys.stderr)


def run(cmd, cwd=None, data=None, check=True):
    p = subprocess.run(cmd, cwd=cwd, input=data, capture_output=True, text=True)
    if check and p.returncode:
        raise RuntimeError("%s: %s" % (" ".join(cmd[:4]), p.stderr.strip()[-400:]))
    return p.stdout


def ok(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True).returncode == 0


def conf_file(name):
    """The path of a conf file: freebsd/<name>, or that of a bundle in the checkout of
    azsupport/ports (PORTS_CONF)."""
    if name in PORTS_CONF:
        return os.path.join(PORTS_DIR, PORTS_CONF[name])
    return os.path.join(ROOT, "freebsd", name)


def conf_ref(name):
    """How an issue names a conf file: `freebsd/<name>`, or `<path>` of azsupport/ports."""
    if name in PORTS_CONF:
        return "`%s` of azsupport/ports" % PORTS_CONF[name]
    return "`freebsd/%s`" % name


def conf(name):
    """Rows of a conf file (conf_file), without comments and blank lines."""
    with open(conf_file(name)) as f:
        rows = (line.split("#", 1)[0].split() for line in f)
        return [r for r in rows if r]


def security_ids(text):
    """The CVE and GHSA ids named in text, sorted: CVE-2026-1234, GHSA-abcd-efgh-ijkl."""
    return sorted(set(i.upper() if i[:3].upper() == "CVE" else "GHSA" + i[4:].lower()
                      for i in re.findall(r"CVE-\d{4}-\d{4,}|GHSA(?:-[0-9a-z]{4}){3}", text, re.I)))


GIT_TIMEOUT = 300


def commit_ids(url, old, new):
    """The CVE and GHSA ids named in the messages of the commits of tag new that tag old
    has not (git log old..new) and the number of those commits. Only the commit objects
    of both tags are fetched (--filter=tree:0), into a temporary repository: the whole
    history of FFmpeg is 37 MB and 4 s so. Not a shallow fetch: --shallow-exclude and
    --shallow-since cut a merge with a parent outside the range off from its other parent
    (lz4 v1.10.0..v1.11.0 gave 1 commit of 862). RuntimeError when they cannot be read."""
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    with tempfile.TemporaryDirectory(prefix="upstream-commits-") as d:
        def git(*args):
            try:
                p = subprocess.run(["git", "-C", d] + list(args), capture_output=True, text=True,
                                   env=env, timeout=GIT_TIMEOUT)
            except subprocess.TimeoutExpired:
                raise RuntimeError("git %s: no answer in %d s" % (args[0], GIT_TIMEOUT))
            if p.returncode:
                raise RuntimeError("git %s: %s" % (args[0], p.stderr.strip()[-300:]))
            return p.stdout
        git("init", "-q", "--bare")
        git("remote", "add", "origin", url)
        ref_old, ref_new = "refs/tags/%s" % old, "refs/tags/%s" % new
        git("fetch", "-q", "--no-tags", "--filter=tree:0", "origin",
            "+%s:%s" % (ref_old, ref_old), "+%s:%s" % (ref_new, ref_new))
        out = git("log", "--format=%B%x00", "%s..%s" % (ref_old, ref_new))
    msgs = [m for m in out.split("\0") if m.strip()]
    return security_ids(out), len(msgs)


def notes_line(url, tag, old=None):
    """What a release says about security, for a release issue. The release notes of
    tag (GitHub releases only: the API, with GH_TOKEN where there is one): the CVE and
    GHSA ids they name, or that they name none. With the tag old of the version built,
    also the ids the commits since old name (any git repository, commit_ids); a line
    when they cannot be read. None for a directory listing or without a tag."""
    if not tag or (url or "").endswith("/"):
        return None
    commits = None
    if old:
        try:
            ids, count = commit_ids(url, old, tag)
            if ids:
                commits = ("Commits since `%s` (%d): they name **%s**: if one of them touches us, take the "
                           "release before the port." % (old, count, ", ".join(ids)))
        except Exception as e:
            warn("%s: the commits %s..%s could not be read: %s" % (url, old, tag, e))
            commits = ("Commits since `%s`: could not be read (%s); look at the changes for CVE and GHSA ids."
                       % (old, str(e).splitlines()[-1][:200] if str(e) else type(e).__name__))
    else:
        log("%s: no tag of the version built, the commits before %s are not read" % (url, tag))
    m = re.match(r"https://github\.com/([^/]+)/([^/]+?)(?:\.git)?/?$", url or "")
    if not m:
        return commits
    api = "https://api.github.com/repos/%s/%s/releases/tags/%s" % (m.group(1), m.group(2), tag)
    headers = {"User-Agent": "upstream-check (azsupport/php-src)", "Accept": "application/vnd.github+json"}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    try:
        with urllib.request.urlopen(urllib.request.Request(api, headers=headers), timeout=30) as r:
            body = json.loads(r.read().decode("utf-8", "replace")).get("body") or ""
    except Exception:
        notes = "Release notes: no GitHub release for the tag `%s` (or it could not be read); look at the changes." % tag
    else:
        ids = security_ids(body)
        if ids:
            notes = "Release notes: they name **%s**. If one of them touches us, take the release before the port." % ", ".join(ids)
        elif re.search(r"secur|vulnerab", body, re.I):
            notes = "Release notes: they speak of security without a CVE id: read them; if it touches us, take the release before the port."
        elif commits:
            notes = "Release notes: no CVE or GHSA id."
        else:
            notes = "Release notes: no CVE or GHSA id, nothing on security: wait for the port."
    return "\n\n".join(n for n in (notes, commits) if n)


def http(url):
    req = urllib.request.Request(url, headers={"User-Agent": "upstream-check (azsupport/php-src)"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", "replace")


def vkey(v):
    """Sort key of 6.3.0, 4.0.5.2, 8.2, 2.0.6RC1, 3.2.17RC1, 2.0.1b; None for anything else."""
    m = re.fullmatch(r"(\d+(?:\.\d+){0,3})(?:[-.]?(alpha|beta|rc|a|b)\.?(\d*))?", v or "", re.I)
    if not m:
        return None
    nums = [int(x) for x in m.group(1).split(".")]
    nums += [0] * (4 - len(nums))
    stage = STAGE[m.group(2).lower()] if m.group(2) else 3
    return tuple(nums) + (stage, int(m.group(3) or 0))


# Tag prefixes that name a project, and the project. Such a tag is a release only
# in the repository of that project: c-ares keeps the tags curl-7_14_0 ... curl-7_19_4
# of the curl releases it once came with.
PROJECT_PREFIXES = {
    "curl-": "curl", "cares-": "c-ares", "c-ares-": "c-ares", "pcre2-": "pcre2",
    "libidn2-": "libidn2", "libpsl-": "libpsl", "nghttp2-": "nghttp2",
    "libunistring-": "libunistring", "memcache-": "memcache", "libssh2-": "libssh2",
}


def tag_version(tag, name=None):
    """Version of a release tag: 6.3.0, v3.4.0, release-2.0.1, RELEASE_3_0_6, memcache-3.0.8,
    curl-8_23_0, pcre2-10.49, cares-1_34_4, libidn2-2.3.8, libpsl-0.21.5. With the name of
    the project (as in the conf files), a tag with the prefix of another project is none."""
    for prefix in sorted(PROJECT_PREFIXES, key=len, reverse=True):
        if tag.startswith(prefix):
            if name and PROJECT_PREFIXES[prefix] != name:
                return None
            tag = tag[len(prefix):]
            if re.fullmatch(r"\d+(_\d+)+", tag):
                tag = tag.replace("_", ".")
            break
    if tag.startswith("RELEASE_"):
        tag = tag[len("RELEASE_"):].replace("_", ".")
    v = re.sub(r"^(v|release-)", "", tag)
    return v if vkey(v) else None


# What is built from FreeBSD ports, each from a conf file of its own: (conf file,
# name, where it goes, the workflow that builds it, the steps after a take line).
# The builds are the ports of azsupport/ports, with their conf files and patches there.
PORTS_CONF = {
    "deps.conf": "az/az/files/deps.conf",
    "ffmpeg.conf": "multimedia/ffmpeg/files/ffmpeg.conf",
    "imagemagick.conf": "graphics/ImageMagick7/files/imagemagick.conf",
}
# the checkout of azsupport/ports (main() sets it from --ports)
PORTS_DIR = os.path.join(ROOT, "ports")
# where the reviewed revision of the ports of a bundle is kept
KEPT_BUNDLE = "the ports commit of %s of azsupport/ports"
PORTS_BUILD = "build.yml of azsupport/ports"
PORTS_STEPS = ("run %s on main with `publish` (https://github.com/azsupport/ports/actions/workflows/build.yml: "
               "it builds and tests the packages and publishes the release `az-fbsd<major>-amd64-<level>` "
               "when everything passed).")
BUNDLES = [(c, n, w, PORTS_BUILD, PORTS_STEPS % PORTS_BUILD) for c, n, w in (
    ("deps.conf", "phpdeps", "the packages az (/usr/local/az) and curl"),
    ("ffmpeg.conf", "ffmpeg", "the package ffmpeg"),
    ("imagemagick.conf", "imagemagick", "the packages ImageMagick6 and ImageMagick7"),
)]
# Slave ports whose patches and build are in their master port.
MASTER_PORTS = {"multimedia/libx264": "multimedia/x264"}


def deps_rows(kind, cfile="deps.conf"):
    """The rows of a conf file of a bundle (deps.conf, ffmpeg.conf, imagemagick.conf of
    azsupport/ports) of one kind ("ports", "lib", "take", "upstream"), without it."""
    if not os.path.exists(conf_file(cfile)):
        return []
    return [r[1:] for r in conf(cfile) if r[0] == kind]


def deps_ports(cfile):
    """{name: port} of the lib lines, the im lines (an ImageMagick of
    imagemagick.conf) and the program lines (FFmpeg of ffmpeg.conf) of a conf file."""
    return {r[0]: r[1] for r in deps_rows("lib", cfile) + deps_rows("im", cfile) + deps_rows("program", cfile)
            if len(r) > 1}


def ports_conf(cfile="deps.conf"):
    """The conf file that has the ports commit of cfile: its own ports line, else
    deps.conf (ffmpeg.conf and imagemagick.conf build with the commit of the libraries)."""
    return cfile if deps_rows("ports", cfile) else "deps.conf"


def deps_ports_commit(cfile="deps.conf"):
    rows = deps_rows("ports", ports_conf(cfile))
    return rows[0][0] if rows else None


def bundle_key(bundle):
    """The part of the issue keys for a bundle: "deps" for phpdeps (the keys of before)."""
    return "deps" if bundle == "phpdeps" else bundle


def norm_version(v):
    """79-1, 2-15-0, 76_1: the digits joined with dots."""
    return re.sub(r"(?<=\d)[-_](?=\d)", ".", v)


def deps_versions(source, pattern, series):
    """The final releases of a library of phpdeps or FFmpeg: the tags of a git repository, or the
    names in a directory listing (a source ending in "/"), that match the pattern
    (group 1 the version, or a group "patch", a patch level of the series)."""
    rx = re.compile(pattern) if pattern else None
    if source.endswith("/"):
        names = [n.rstrip("/").rsplit("/", 1)[-1] for n in re.findall(r'href="([^"?#]+)"', http(source))]
    else:
        names = [l.split("refs/tags/", 1)[-1] for l in run(["git", "ls-remote", "--tags", "--refs", source]).splitlines()]
    found = {}
    for name in names:
        if rx:
            m = rx.fullmatch(name)
            if not m:
                continue
            if "patch" in rx.groupindex:
                if not series:
                    continue
                v = "%s.%d" % (series, int(m.group("patch")))
            else:
                v = norm_version(m.group(1))
        else:
            v = tag_version(name)
            if not v:
                continue
        k = vkey(v)
        if not k or k[4] != 3:
            continue  # not a final release
        if series and not (v == series or v.startswith(series + ".")):
            continue
        found.setdefault(v, name)
    return found


def check_deps_releases():
    """New upstream releases of the libraries built from ports (phpdeps, FFmpeg)."""
    findings, checked = [], set()
    for cfile, bundle, prefix, _workflow, steps in BUNDLES:
        more, chk = check_bundle_releases(cfile, bundle, prefix, steps)
        findings += more
        checked |= chk
    return findings, checked


def check_bundle_releases(cfile, bundle, prefix, steps):
    findings, checked = [], set()
    kb = bundle_key(bundle)
    ports = deps_ports(cfile)
    takes = {r[0]: r[1] for r in deps_rows("take", cfile)}
    for row in deps_rows("upstream", cfile):
        name, built, source = row[0], row[1], row[2]
        pattern = row[3] if len(row) > 3 else None
        series = row[4] if len(row) > 4 else None
        try:
            found = deps_versions(source, pattern, series)
        except Exception as e:
            warn("%s %s: no releases from %s: %s" % (bundle, name, source, e))
            continue
        checked.add("release:%s:%s:" % (kb, name))
        if not found:
            warn("%s %s: nothing in %s matches %s" % (bundle, name, source, pattern))
            continue
        if name in takes and takes[name] != built and not (series and "patch" in (pattern or "")):
            warn("%s %s: the upstream line says %s, the take line %s" % (bundle, name, built, takes[name]))
        newest = max(found, key=vkey)
        if not vkey(norm_version(built)) or vkey(newest) <= vkey(norm_version(built)):
            continue
        port = ports.get(name, "?")
        where = "listing" if source.endswith("/") else "tag `%s`" % found[newest]
        notes = notes_line(source, found[newest], found.get(norm_version(built)))
        lines = [
            "**%s %s** is out (%s of %s)." % (name, newest, where, source),
            "",
            "Built now in `%s`: %s (`%s`, %s)%s." % (
                prefix, built, port, conf_ref(cfile), ", the release of its take line" if name in takes else ", the version of the port"),
            "",
        ] + ([notes, ""] if notes else []) + [
            "By the rule it comes with the port `%s`: when the port has it, move the ports commit of "
            "%s and the version of the upstream line, then %s This issue closes then. Before the "
            "port only when it fixes a vulnerability that touches us or a bug we have: then a take line in "
            "%s (the release file, its SHA-256 checked against a second source such as a signature "
            "or the checksums of another distribution, the source directory inside it: the workflow take-sources.yml "
            "of azsupport/ports), the patches of the port checked against it (its deps-take-check.yml; ones brought "
            "up to %s into `az/az/files/deps/%s-%s/`), and the same steps." % (
                port, conf_ref(ports_conf(cfile)), steps, conf_ref(cfile), newest, name, newest),
        ]
        findings.append({
            "key": "release:%s:%s:%s" % (kb, name, newest),
            "kind": "release",
            "title": "%s: %s %s is out (built: %s)" % (bundle, name, newest, built),
            "body": "\n".join(lines),
        })
    return findings, checked


def check_takes(git):
    """A port of phpdeps or FFmpeg that has caught up with the release of its take line."""
    findings, checked = [], set()
    for cfile, bundle, _prefix, _workflow, steps in BUNDLES:
        kt = "take:" if bundle == "phpdeps" else "take:%s:" % bundle
        ports = deps_ports(cfile)
        for row in deps_rows("take", cfile):
            name, ver = row[0], row[1]
            port = ports.get(name)
            if not port or port == "bundle":
                continue
            pv = port_version(git, port)
            if not pv:
                continue
            checked.add("%s%s:" % (kt, name))
            if vkey(norm_version(pv)) and vkey(ver) and vkey(norm_version(pv)) >= vkey(ver):
                findings.append({
                    "key": "%s%s:%s" % (kt, name, ver),
                    "kind": "ports",
                    "title": "%s: %s has %s now, the take line of %s %s can go" % (bundle, port, pv, name, ver),
                    "body": "freebsd-ports `%s` (main) has version %s; %s takes %s %s before it "
                            "(take line). To go back to the port: move the ports commit of %s to one "
                            "with that version, delete the take line (and `az/az/files/deps/%s-%s/` of "
                            "azsupport/ports, if there is one and no other conf file takes it), set the upstream "
                            "line to the version of the port, then %s The next check closes this issue." % (
                                port, pv, conf_ref(cfile), name, ver, conf_ref(ports_conf(cfile)), name, ver, steps),
                })
    return findings, checked


def curl_deps():
    """Rows of freebsd/curl-deps.conf: name version port repository distfile sha256 url."""
    if not os.path.exists(os.path.join(ROOT, "freebsd", "curl-deps.conf")):
        return []
    return [r for r in conf("curl-deps.conf") if len(r) >= 7]


def php_fits(target, rng):
    """Whether PHP <target> (X.Y) is in rng = (min, max); None when rng is unknown."""
    if not rng:
        return None
    lo, hi = (vkey(x) if x else None for x in rng)
    first, last = vkey(target + ".0"), vkey(target + ".999")
    return not (lo and lo > last) and not (hi and hi < first)


def composer_range(constraint):
    """(min, max) of a composer "php" constraint such as ">=7.4", "^7.4 || ^8.0",
    ">= 7.2, < 8.5"; max only when every alternative has an upper bound."""
    lows, highs = [], []
    for op, ver in re.findall(r"(>=|<=|>|<|\^|~|==|=)?\s*v?(\d+(?:\.\d+){0,2})", constraint):
        if op in ("<", "<="):
            nums = [int(x) for x in ver.split(".")]
            if op == "<=":
                nums += [999] * (3 - len(nums))
            else:
                while len(nums) > 1 and nums[-1] == 0:
                    nums.pop()
                nums[-1] -= 1
                nums += [999] * (3 - len(nums))
            highs.append(".".join(str(n) for n in nums))
        else:
            lows.append(ver)
    alternatives = constraint.count("||") + 1
    hi = max(highs, key=vkey) if highs and len(highs) >= alternatives else None
    return (min(lows, key=vkey) if lows else None, hi)


def range_text(rng):
    if not rng:
        return "unknown (no package.xml or composer.json at the tag, not on PECL)"
    lo, hi = rng
    return "%s%s" % (lo or "?", " to " + hi if hi else " and later")


class Upstream:
    """Releases of one extension, from the tags of its repository and from PECL."""

    def __init__(self, name, url, workdir):
        self.name, self.url = name, url
        self.git = os.path.join(workdir, "ext-" + name)
        self.tags, self.pecl, self.ranges = {}, {}, {}
        self.sources = 0
        try:
            for line in run(["git", "ls-remote", "--tags", "--refs", url]).splitlines():
                tag = line.split("refs/tags/", 1)[-1]
                v = tag_version(tag, name)
                if v:
                    self.tags.setdefault(v, tag)
            self.sources += 1
        except RuntimeError as e:
            warn("%s: no tags from %s: %s" % (name, url, e))
        try:
            if name in ("curl", "pcre2") or name in {r[0] for r in curl_deps()}:
                raise RuntimeError("not a PECL package")
            xml = http("%s/%s/allreleases.xml" % (PECL_REST, name.lower()))
            for v, s in re.findall(r"<r>\s*<v>([^<]+)</v>\s*<s>([^<]+)</s>", xml):
                if vkey(v):
                    self.pecl[v.strip()] = s.strip()
            self.sources += 1
        except Exception as e:
            log("%s: no PECL releases: %s" % (name, e))

    def stable(self, v):
        """A final release: no alpha, beta or RC in its name, and stable on PECL where
        PECL has it (PECL lists igbinary 3.2.17RC1 as stable, memcache 3.0.8 as beta)."""
        return vkey(v)[4] == 3 and self.pecl.get(v, "stable") == "stable"

    def versions(self):
        return set(self.tags) | set(self.pecl)

    def php_range(self, v):
        if v not in self.ranges:
            self.ranges[v] = self._from_tag(v) or self._from_pecl(v)
        return self.ranges[v]

    def tag_commit(self, v):
        """(tag, commit) of release v; the commit is what pecl.conf wants."""
        tag = self.tags.get(v)
        if not tag:
            return None, None
        try:
            out = run(["git", "ls-remote", self.url, "refs/tags/%s" % tag, "refs/tags/%s^{}" % tag])
        except RuntimeError:
            return tag, None
        refs = {}
        for line in out.splitlines():
            if "\t" in line:
                sha, ref = line.split("\t", 1)
                refs[ref] = sha
        return tag, refs.get("refs/tags/%s^{}" % tag) or refs.get("refs/tags/%s" % tag)

    def _from_tag(self, v):
        tag = self.tags.get(v)
        if not tag:
            return None
        if not os.path.isdir(self.git):
            run(["git", "init", "-q", "--bare", self.git])
            run(["git", "remote", "add", "origin", self.url], cwd=self.git)
        try:
            run(["git", "fetch", "-q", "--depth", "1", "--filter=blob:none", "origin",
                 "+refs/tags/%s:refs/tags/%s" % (tag, tag)], cwd=self.git)
        except RuntimeError:
            return None
        xml = run(["git", "show", "refs/tags/%s:package.xml" % tag], cwd=self.git, check=False)
        m = re.search(r"<required>.*?<php>(.*?)</php>", xml, re.S)
        if m:
            lo = re.search(r"<min>\s*([^<\s]+)", m.group(1))
            hi = re.search(r"<max>\s*([^<\s]+)", m.group(1))
            return (lo.group(1) if lo else None, hi.group(1) if hi else None)
        # Extensions that left PECL for PIE keep only composer.json.
        try:
            req = json.loads(run(["git", "show", "refs/tags/%s:composer.json" % tag],
                                 cwd=self.git, check=False) or "{}").get("require", {}).get("php")
        except ValueError:
            req = None
        return composer_range(req) if req else None

    def _from_pecl(self, v):
        if v not in self.pecl:
            return None
        try:
            txt = http("%s/%s/deps.%s.txt" % (PECL_REST, self.name.lower(), v))
        except Exception:
            return None
        m = re.search(r's:3:"php";a:\d+:\{(.*?)\}', txt)
        if not m:
            return None
        lo = re.search(r's:3:"min";s:\d+:"([^"]*)"', m.group(1))
        hi = re.search(r's:3:"max";s:\d+:"([^"]*)"', m.group(1))
        return (lo.group(1) if lo else None, hi.group(1) if hi else None)


def newest_fitting(up, target, cur, pin):
    """The newest release after cur for PHP <target>, None if there is none.

    Only the newest release of each X.Y series is looked at, newest series first:
    that keeps the PHP checks to one per series."""
    pre = not up.stable(cur) if cur in up.pecl else vkey(cur)[4] < 3
    cands = [v for v in up.versions() if vkey(v) > vkey(cur) and (pre or up.stable(v))]
    if pin:
        cands = [v for v in cands if v == pin or v.startswith(pin + ".")]
    seen = set()
    for v in sorted(cands, key=vkey, reverse=True):
        series = vkey(v)[:2]
        if series in seen:
            continue
        seen.add(series)
        if php_fits(target, up.php_range(v)) is not False:
            return v
    return None


def check_releases(workdir, pins):
    rows = {}
    for target, name, version, url, _commit in conf("pecl.conf"):
        rows.setdefault(name, []).append((target, version, url))
    if os.path.exists(os.path.join(ROOT, "freebsd", "curl.conf")):
        for target, version, _url, _sha in conf("curl.conf"):
            rows.setdefault("curl", []).append((target, version, "https://github.com/curl/curl"))
    if os.path.exists(os.path.join(ROOT, "freebsd", "pcre.conf")):
        for target, version, _url, _sha in conf("pcre.conf"):
            if not version.startswith("8."):
                rows.setdefault("pcre2", []).append((target, version, "https://github.com/PCRE2Project/pcre2"))
    libs = {}
    for name, version, port, repo, _df, _sha, _url in curl_deps():
        if repo != "-":
            rows.setdefault(name, []).append(("all", version, repo))
            libs[name] = port
    findings, checked = [], set()
    for name, entries in rows.items():
        up = Upstream(name, entries[0][2], workdir)
        if not up.sources:
            continue
        checked.add("release:%s:" % name)
        news = {}
        for target, cur, _url in entries:
            if name in libs:
                v = newest_lib(up, cur)
            else:
                v = newest_fitting(up, target, cur, pins.get(name))
            if v:
                news.setdefault(v, []).append((target, cur))
        for v, hits in sorted(news.items(), key=lambda x: vkey(x[0])):
            if name in libs:
                findings.append(lib_finding(up, v, hits[0][1], libs[name]))
            else:
                findings.append(release_finding(up, v, hits, pins.get(name)))
    return findings, checked


def newest_lib(up, cur):
    """The newest final release after cur (the libraries of the bundled curl)."""
    cands = [v for v in up.tags if vkey(v) and vkey(cur) and vkey(v) > vkey(cur) and vkey(v)[4] == 3]
    return max(cands, key=vkey) if cands else None


def lib_finding(up, v, cur, port):
    tag = up.tags.get(v)
    links = []
    if tag and "github.com/" in up.url:
        base = up.url[:-4] if up.url.endswith(".git") else up.url
        links.append("[tag `%s`](%s/releases/tag/%s)" % (tag, base, tag))
        if cur in up.tags:
            links.append("[changes since %s](%s/compare/%s...%s)" % (cur, base, up.tags[cur], tag))
    notes = notes_line(up.url, tag, up.tags.get(cur))
    lines = [
        "**%s %s** is out: %s." % (up.name, v, ", ".join(links) or up.url),
        "",
        "Bundled now: %s, in `freebsd/curl-deps.conf`: a library of the bundled curl "
        "(`--with-curl=bundled` of every branch, and `/usr/local/phpdeps`)." % cur,
        "",
    ] + ([notes, ""] if notes else []) + [
        "By the rule it comes with the port `%s` (this check reports when its distinfo has a release file "
        "the bundle has not): then in `freebsd/curl-deps.conf` set version `%s`, the release file and the "
        "SHA-256 of the distinfo of the port, carry over `freebsd/curl/%s-<old version>.patch` if there is "
        "one, check that `freebsd/curl/build-libcurl.sh` still builds it (its file lists, configure options), "
        "then run the build test. Before the port only when it fixes a vulnerability that touches us or a bug "
        "we have (the SHA-256 then checked against a second source: a signature, the checksums of the release "
        "or of another distribution). Not wanted: close this issue." % (port, v, up.name),
    ]
    return {
        "key": "release:%s:%s" % (up.name, v),
        "kind": "release",
        "title": "%s %s is out (bundled with curl: %s)" % (up.name, v, cur),
        "body": "\n".join(lines),
    }


def release_finding(up, v, hits, pin):
    tag, commit = up.tag_commit(v)
    rng = up.php_range(v)
    current = sorted({c for _t, c in hits}, key=vkey)
    targets = " ".join(t for t, _c in hits)
    links = []
    if tag:
        links.append("[tag `%s`](%s/releases/tag/%s)" % (tag, up.url, tag))
        for c in current:
            if c in up.tags:
                links.append("[changes since %s](%s/compare/%s...%s)" % (c, up.url, up.tags[c], tag))
    if v in up.pecl:
        links.append("[PECL](https://pecl.php.net/package/%s/%s)" % (up.name, v))
    lines = [
        "**%s %s** is out (%s): %s." % (up.name, v, up.pecl.get(v, "stable"), ", ".join(links) or up.url),
        "",
        "PHP: %s%s." % (range_text(rng), "; pinned series %s" % pin if pin else ""),
        "",
        "| Target | Bundled now |",
        "|---|---|",
    ]
    lines += ["| %s | %s |" % (t, c) for t, c in hits]
    oldest = next((up.tags[c] for c in current if c in up.tags), None)
    notes = notes_line(up.url, tag, oldest)
    if notes:
        lines += ["", notes]
    if up.name == "pcre2":
        lines[2] = "Bundled in place of the PCRE2 of php-src (freebsd/pcre.conf)."
        lines += [
            "",
            "By the rule it comes with `devel/pcre2` (before the port only when it fixes a vulnerability that "
            "touches us or a bug we have): in `freebsd/pcre.conf` set version `%s`, the release tarball and its "
            "SHA-256 (that of the distinfo of the port); run "
            "`freebsd/pcre/import-pcre2.sh <tree> <unpacked release>` on a tree of each target, build it "
            "and run `ext/pcre/tests` (new messages of the library may need "
            "`freebsd/pcre/tests-<target>.patch`), then the build test. Not wanted: close this issue." % v,
        ]
        return {
            "key": "release:pcre2:%s" % v,
            "kind": "release",
            "title": "PCRE2 %s is out (bundled: %s for %s)" % (v, ", ".join(current), targets),
            "body": "\n".join(lines),
        }
    if up.name == "curl":
        lines[2] = "It needs OpenSSL 3.0 or later, as the bundled curl does now."
        lines += [
            "",
            "By the rule it comes with `ftp/curl` (before the port only when it fixes a vulnerability that "
            "touches us or a bug we have; curl names the CVEs it fixes): in "
            "`freebsd/curl.conf` set version `%s`, the release tarball and its SHA-256, and bring "
            "`freebsd/curl/curl-<old version>.patch` up to date from `ftp/curl/files/patch-configure`; "
            "check that `freebsd/curl/build-libcurl.sh` passes no option the new configure has dropped, "
            "then run the build test. Not wanted: close this issue." % v,
        ]
        return {
            "key": "release:curl:%s" % v,
            "kind": "release",
            "title": "curl %s is out (bundled: %s for %s)" % (v, ", ".join(current), targets),
            "body": "\n".join(lines),
        }
    lines += [
        "",
        "To take it: in `freebsd/pecl.conf` set version `%s` and commit `%s` for %s, carry over "
        "`freebsd/pecl/%s-<old version>.patch` if there is one, then run the build test. "
        "Not wanted (a series we stay on, a PHP we leave behind): close this issue, "
        "the check does not reopen it." % (v, commit or "<the tag's commit>", targets, up.name),
    ]
    return {
        "key": "release:%s:%s" % (up.name, v),
        "kind": "release",
        "title": "%s %s is out (bundled: %s for %s)" % (up.name, v, ", ".join(current), targets),
        "body": "\n".join(lines),
    }


def ports_followed():
    """(ports dir, reviewed revision, where the revision is kept)."""
    # a 4th column names the port of azsupport/ports that builds it (devel/t1lib)
    ports = [(r[1], r[2], "freebsd/upstream.conf" + (" (for `%s` of azsupport/ports)" % r[3] if len(r) > 3 else ""))
             for r in conf("upstream.conf") if r[0] == "port"]
    listed = {p for p, _r, _k in ports}
    for cfile, _bundle, _prefix, _workflow, _steps in BUNDLES:
        commit = deps_ports_commit(cfile)
        if not commit:
            continue
        for name, port in deps_ports(cfile).items():
            for p in (port, MASTER_PORTS.get(port)):
                if p and p != "bundle" and p not in listed:
                    listed.add(p)
                    ports.append((p, commit, KEPT_BUNDLE % PORTS_CONF[ports_conf(cfile)]))
    seen = set()
    for target, _url, _ref, port, portrev in conf("targets.conf"):
        if port not in seen:
            seen.add(port)
            ports.append(("lang/" + port, portrev, "portrev in freebsd/targets.conf"))
    return ports


def check_ports(workdir, days):
    git = os.path.join(workdir, "freebsd-ports")
    if not os.path.isdir(git):
        run(["git", "init", "-q", "--bare", git])
        run(["git", "remote", "add", "origin", PORTS_URL], cwd=git)
    since = (datetime.date.today() - datetime.timedelta(days=days)).isoformat()
    try:
        run(["git", "fetch", "-q", "--filter=blob:none", "--shallow-since=" + since,
             "origin", "+main:refs/heads/main"], cwd=git)
    except RuntimeError as e:
        warn("freebsd-ports: %s" % e)
        return [], set()
    findings, checked = [], set()
    for port, rev, kept in ports_followed():
        exists = ok(["git", "cat-file", "-e", "main:" + port], cwd=git)
        if not exists and port.startswith("lang/"):
            continue  # an old PHP whose port is gone long ago: nothing to follow
        checked.add("ports:%s:" % port)
        base = run(["git", "rev-parse", "--verify", "-q", rev + "^{commit}"], cwd=git, check=False).strip()
        if not base:
            warn("%s: reviewed revision %s is not in the last %d days of freebsd-ports" % (port, rev, days))
        log_range = "%s..main" % base if base else "main"
        out = run(["git", "log", "--format=%H%x09%cs%x09%s", log_range, "--", port], cwd=git)
        commits = []
        for line in out.splitlines():
            sha, date, subject = line.split("\t", 2)
            names = run(["git", "show", "--format=", "--name-status", sha, "--", port], cwd=git)
            files = [l.split("\t")[-1] for l in names.splitlines() if "\t" in l]
            patches = [f for f in files if "/files/" in f]
            make = []
            if port + "/Makefile" in files:
                diff = run(["git", "show", "--format=", sha, "--", port + "/Makefile"], cwd=git)
                make = [l for l in diff.splitlines()
                        if l[:1] in "+-" and not l.startswith(("+++", "---")) and not VERSION_LINE.match(l)]
            removed = any(l[:1] in "DR" for l in names.splitlines())
            if patches or make or removed:
                commits.append((sha, date, subject, files, patches, make))
        moved = None
        if not exists:
            for line in run(["git", "show", "main:MOVED"], cwd=git).splitlines():
                if line.startswith(port + "|"):
                    moved = line.split("|")
        if commits or not exists:
            findings.append(port_finding(git, port, rev, kept, commits, moved, base))
    more, chk = check_distinfo(git)
    more2, chk2 = check_takes(git)
    return findings + more + more2, checked | chk | chk2


def github_json(path):
    """GET of the REST API of GitHub (with the token of the workflow when there is one)."""
    headers = {"User-Agent": "upstream-check (azsupport/php-src)", "Accept": "application/vnd.github+json"}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request("https://api.github.com/" + path, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


TREES = {"gentoo": ("gentoo/gentoo", "Gentoo"), "openbsd": ("openbsd/ports", "OpenBSD")}


def ours(what):
    """What of ours a row of upstream.conf is for (its last column): a port of
    azsupport/ports, a library of az ("az/az:<library>") or a branch of this fork
    ("freebsd/<version>")."""
    if what.startswith("freebsd/"):
        return "`%s` of this fork" % what
    if what.startswith("az/az:"):
        return "the library %s of az (`az/az` of azsupport/ports)" % what.split(":", 1)[1]
    return "`%s` of azsupport/ports" % what


def check_trees():
    """The rows "gentoo <dir> <date> <ours>" and "openbsd <dir> <date> <ours>" of
    upstream.conf: the commits of gentoo/gentoo or openbsd/ports (the GitHub mirror of
    the CVS tree of OpenBSD) to <dir> after <date>, the fixes those trees carry."""
    findings, checked = [], set()
    for r in conf("upstream.conf"):
        if r[0] not in TREES or len(r) < 4:
            continue
        kind, (repo, name) = r[0], TREES[r[0]]
        d, date, what = r[1], r[2], r[3]
        try:
            commits = github_json("repos/%s/commits?path=%s&since=%sT23:59:59Z&per_page=50" % (repo, d, date))
        except Exception as e:  # noqa: BLE001 - the source is down: leave its issue alone
            warn("%s %s: %s" % (repo, d, e))
            continue
        checked.add("%s:%s:" % (kind, d))
        if not commits:
            continue
        lines = ["Commits of [%s](https://github.com/%s/tree/master/%s) to `%s` after %s (newest first), for %s:"
                 % (repo, repo, d, d, date, ours(what)), ""]
        for c in commits:
            msg = c["commit"]["message"].splitlines()[0].replace("|", "\\|")
            lines.append("- [`%s`](https://github.com/%s/commit/%s) %s %s" % (
                c["sha"][:12], repo, c["sha"], c["commit"]["committer"]["date"][:10], msg))
        lines += ["", "After the review: what %s needs (a fix it lacks) into its patches, then set the date of "
                      "`%s %s` in `freebsd/upstream.conf` to the day of the review; the next check closes this issue."
                      % (ours(what), kind, d)]
        findings.append({"key": "%s:%s:%s" % (kind, d, date), "kind": "release" if what.startswith("freebsd/") else "ports",
                         "title": "%s: %s, %d commit%s after %s" % (name, d, len(commits),
                                                                   "" if len(commits) == 1 else "s", date),
                         "body": "\n".join(lines)})
    return findings, checked



def check_github():
    """The rows "github <owner>/<repo>@<branch> <commit> <ours>" of upstream.conf: the
    commits of a branch of an upstream on GitHub after <commit>, the last one reviewed,
    for a port of ours ahead of its FreeBSD port (3proxy: the fixes of its LTS branch
    after the release we build)."""
    findings, checked = [], set()
    for r in conf("upstream.conf"):
        if r[0] != "github" or len(r) < 4:
            continue
        src, base, what = r[1], r[2], r[3]
        repo, _, branch = src.partition("@")
        branch = branch or "master"
        try:
            cmp = github_json("repos/%s/compare/%s...%s" % (repo, base, urllib.parse.quote(branch, safe="")))
        except Exception as e:  # noqa: BLE001 - the source is down: leave its issue alone
            warn("%s %s: %s" % (repo, branch, e))
            continue
        checked.add("github:%s:" % src)
        commits = cmp.get("commits") or []
        if not commits and cmp.get("status") in ("identical", "behind"):
            continue
        n = cmp.get("ahead_by", len(commits))
        lines = ["Commits of the branch [`%s`](https://github.com/%s/commits/%s) of %s after `%s` (oldest first), "
                 "for %s:" % (branch, repo, branch, repo, base, ours(what)), ""]
        if cmp.get("status") == "diverged":
            lines += ["The branch no longer has `%s` (rewritten): review it whole." % base, ""]
        for c in commits:
            msg = c["commit"]["message"].splitlines()[0].replace("|", "\\|")
            lines.append("- [`%s`](https://github.com/%s/commit/%s) %s %s" % (
                c["sha"][:12], repo, c["sha"], c["commit"]["committer"]["date"][:10], msg))
        lines += ["", "After the review: what %s needs (a fix it lacks) into its patches, then set the commit of "
                      "`github %s` in `freebsd/upstream.conf` to the newest one reviewed; the next check closes "
                      "this issue." % (ours(what), src)]
        findings.append({"key": "github:%s:%s" % (src, base), "kind": "ports",
                         "title": "%s %s: %d commit%s after %s" % (repo, branch, n, "" if n == 1 else "s", base[:12]),
                         "body": "\n".join(lines)})
    return findings, checked


# the advisories of Debian (security team: DSA; LTS: DLA) and of Freexian's Extended LTS
# (ELA), as their security trackers keep them: one entry per advisory, with its
# packages, CVEs and the fixed versions per release
DEBIAN_LISTS = (
    ("https://salsa.debian.org/security-tracker-team/security-tracker/-/raw/master/data/DSA/list",
     "https://security-tracker.debian.org/tracker/%s"),
    ("https://salsa.debian.org/security-tracker-team/security-tracker/-/raw/master/data/DLA/list",
     "https://security-tracker.debian.org/tracker/%s"),
    ("https://salsa.debian.org/freexian-team/extended-lts/security-tracker/-/raw/master/data/ELA/list",
     "https://deb.freexian.com/extended-lts/tracker/%s"),
)
ADVISORY_HEAD = re.compile(r"^\[(\d{1,2}) (\w{3}) (\d{4})\] ((?:DSA|DLA|DTSA|ELA)-\d+(?:-\d+)?) (\S+)(?: - (.*))?$")
ADVISORY_FIX = re.compile(r"^\[(\S+)\] - (\S+) (\S+)")
CHANGELOG_HEAD = re.compile(r"^(\S+) \(([^)]+)\) ([^;]+);.*urgency=(\S+)")


def debian_advisories():
    """{package: [advisory]} of the lists of DEBIAN_LISTS, and whether all of them were read."""
    by_pkg, complete = {}, True
    for url, link in DEBIAN_LISTS:
        try:
            text = http(url)
        except Exception as e:  # noqa: BLE001
            warn("%s: %s" % (url, e))
            complete = False
            continue
        cur, advs = None, []
        for line in text.splitlines():
            m = ADVISORY_HEAD.match(line)
            if m:
                try:
                    day = datetime.datetime.strptime(" ".join(m.group(1, 2, 3)), "%d %b %Y").date().isoformat()
                except ValueError:
                    cur = None
                    continue
                cur = {"date": day, "id": m.group(4), "title": "%s %s" % (m.group(5), m.group(6) or ""),
                       "url": link % m.group(4), "pkgs": {m.group(5)}, "cves": [], "fixed": []}
                advs.append(cur)
                continue
            if cur is None:
                continue
            s = line.strip()
            if s.startswith("{"):
                cur["cves"] += s.strip("{}").split()
            f = ADVISORY_FIX.match(s)
            if f:
                cur["pkgs"].add(f.group(2))
                cur["fixed"].append("%s %s" % (f.group(1), f.group(3)))
        for a in advs:
            for pkg in a["pkgs"]:
                by_pkg.setdefault(pkg, []).append(a)
        if not advs:
            warn("%s: no advisory read (has the format changed?)" % url)
            complete = False
    return by_pkg, complete


def parse_changelog(text, after):
    """The entries of a Debian changelog dated after <after> (YYYY-MM-DD), newest first:
    (version, distribution, urgency, date, lines)."""
    out, cur = [], None
    for line in text.splitlines():
        m = CHANGELOG_HEAD.match(line)
        if m:
            cur = [m.group(2), m.group(3).strip(), m.group(4), "", []]
            continue
        if cur is None:
            continue
        if line.startswith(" -- "):
            dm = re.search(r">\s+(.+)$", line)
            try:
                cur[3] = email.utils.parsedate_to_datetime(dm.group(1)).date().isoformat()
            except (AttributeError, TypeError, ValueError):
                cur[3] = ""
            if cur[3] and cur[3] <= after:
                break
            out.append(tuple(cur))
            cur = None
        elif line.strip():
            cur[4].append(line.rstrip())
    return out


def changelog_lines(entries, limit=12):
    lines = []
    for version, dist, urgency, day, text in entries:
        lines.append("- %s `%s` (%s, urgency=%s)" % (day or "?", version, dist, urgency))
        lines += ["    %s" % t.strip() for t in text[:limit]]
        if len(text) > limit:
            lines.append("    ... (%d more lines)" % (len(text) - limit))
    return lines


def check_debian():
    """The rows "debian <source package> <date> <ours> [uploads]" of upstream.conf: the
    advisories of Debian (DSA, DLA) and of Freexian's Extended LTS (ELA) for the package
    after <date>, with "uploads" also its uploads to unstable after <date> (its
    changelog): the fixes a Debian
    package carries, also for programs whose upstream is gone and for PHP branches out
    of upstream support (php7.4, php7.3 and php7.0 in ELTS)."""
    findings, checked = [], set()
    rows = [r for r in conf("upstream.conf") if r[0] == "debian" and len(r) >= 4]
    if not rows:
        return findings, checked
    by_pkg, complete = debian_advisories()
    for r in rows:
        pkg, date, what = r[1], r[2], r[3]
        advs = sorted((a for a in by_pkg.get(pkg, []) if a["date"] > date), key=lambda a: (a["date"], a["id"]),
                      reverse=True)
        prefix = pkg[:4] if pkg.startswith("lib") else pkg[0]
        cl_url = "https://metadata.ftp-master.debian.org/changelogs//main/%s/%s/unstable_changelog" % (prefix, pkg)
        uploads, cl_ok = [], True
        if len(r) > 4 and r[4] == "uploads":
            try:
                uploads = parse_changelog(http(cl_url), date)
            except urllib.error.HTTPError as e:
                if e.code != 404:  # 404: not in unstable (removed packages)
                    warn("%s: %s" % (cl_url, e))
                    cl_ok = False
            except Exception as e:  # noqa: BLE001
                warn("%s: %s" % (cl_url, e))
                cl_ok = False
        if complete and cl_ok:
            checked.add("debian:%s:" % pkg)
        if not advs and not uploads:
            continue
        lines = ["Debian, the source package `%s` ([security tracker](https://security-tracker.debian.org/tracker/"
                 "source-package/%s), [ELTS tracker](https://deb.freexian.com/extended-lts/tracker/source-package/%s), "
                 "[package](https://tracker.debian.org/pkg/%s)), after %s, for %s." % (pkg, pkg, pkg, pkg, date,
                                                                                         ours(what))]
        if advs:
            lines += ["", "Advisories (newest first):", ""]
            for a in advs[:40]:
                lines.append("- [%s](%s) %s %s: %s; fixed: %s" % (
                    a["id"], a["url"], a["date"], a["title"].strip(), " ".join(a["cves"]) or "no CVE",
                    ", ".join(a["fixed"]) or "-"))
        if uploads:
            lines += ["", "Uploads to unstable ([changelog](%s), newest first):" % cl_url, ""]
            lines += changelog_lines(uploads[:15])
        lines += ["", "After the review: what %s lacks (a fix of a vulnerability that touches us, or a bug we have) "
                      "into its patches, then set the date of `debian %s` in `freebsd/upstream.conf` to the day of "
                      "the review; the next check closes this issue." % (ours(what), pkg)]
        parts = []
        if advs:
            parts.append("%d advisor%s" % (len(advs), "y" if len(advs) == 1 else "ies"))
        if uploads:
            parts.append("%d upload%s" % (len(uploads), "" if len(uploads) == 1 else "s"))
        findings.append({"key": "debian:%s:%s" % (pkg, date),
                         "kind": "release" if what.startswith("freebsd/") else "ports",
                         "title": "Debian: %s, %s after %s" % (pkg, " and ".join(parts), date),
                         "body": "\n".join(lines)[:BODY_LIMIT]})
    return findings, checked


# Launchpad archives: Ondrej Sury's PPA of PHP (deb.sury.org: php5.6 ... php8.x for Debian
# and Ubuntu, with the security fixes he backports to the branches out of upstream
# support) and Ubuntu itself (php8.1 of 22.04, php8.3 of 24.04, fixed by Canonical)
LAUNCHPAD = {
    "sury": ("https://api.launchpad.net/1.0/~ondrej/+archive/ubuntu/php", "Sury",
             "the PPA [ondrej/php](https://launchpad.net/~ondrej/+archive/ubuntu/php/+packages?field.name_filter=%s"
             "&field.status_filter=published) (Ondrej Sury, deb.sury.org)"),
    "ubuntu": ("https://api.launchpad.net/1.0/ubuntu/+archive/primary", "Ubuntu",
               "[Ubuntu](https://launchpad.net/ubuntu/+source/%s) ([security notices](https://ubuntu.com/security/notices))"),
}


def check_launchpad():
    """The rows "sury <source package> <date> <ours>" and "ubuntu <source package> <date>
    <ours>" of upstream.conf: the uploads of the package to the PPA of Ondrej Sury or to
    Ubuntu after <date>, with their changelog entries (the fixes they backport to the PHP
    branches out of upstream support)."""
    findings, checked = [], set()
    for r in conf("upstream.conf"):
        if r[0] not in LAUNCHPAD or len(r) < 4:
            continue
        kind, (api, name, where) = r[0], LAUNCHPAD[r[0]]
        pkg, date, what = r[1], r[2], r[3]
        url = ("%s?ws.op=getPublishedSources&source_name=%s&exact_match=true&order_by_date=true"
               "&created_since_date=%sT23:59:59" % (api, pkg, date))
        try:
            data = json.loads(http(url))
        except Exception as e:  # noqa: BLE001
            warn("Launchpad %s %s: %s" % (kind, pkg, e))
            continue
        checked.add("%s:%s:" % (kind, pkg))
        pubs = [e for e in data.get("entries", [])
                if (e.get("date_published") or e.get("date_created") or "")[:10] > date]
        if not pubs:
            continue
        versions = {}
        for e in pubs:
            base = re.sub(r"\+(ubuntu|deb)\d.*$", "", e.get("source_package_version", "?"))
            versions.setdefault(base, ((e.get("date_published") or e.get("date_created") or "")[:10],
                                       e.get("pocket", "")))
        uploads = []
        try:
            # changelogUrl is in the devel version of the API only (1.0 answers 400)
            cl = json.loads(http(pubs[0]["self_link"].replace("/1.0/", "/devel/", 1) + "?ws.op=changelogUrl"))
            uploads = parse_changelog(http(cl), date)
        except Exception as e:  # noqa: BLE001 - the versions are enough to know there is something
            warn("Launchpad %s %s changelog: %s" % (kind, pkg, e))
        lines = ["Uploads of `%s` to %s after %s, for %s:" % (pkg, where % pkg, date, ours(what)), ""]
        for v, (day, pocket) in sorted(versions.items(), key=lambda x: x[1][0], reverse=True):
            lines.append("- `%s` %s%s" % (v, day, (" (%s)" % pocket) if pocket and pocket != "Release" else ""))
        if uploads:
            lines += ["", "Changelog (newest first):", ""] + changelog_lines(uploads[:10], limit=25)
        lines += ["", "After the review: the fixes %s lacks (each with its upstream commit) into its backports, then "
                      "set the date of `%s %s` in `freebsd/upstream.conf` to the day of the review; the next check "
                      "closes this issue." % (ours(what), kind, pkg)]
        findings.append({"key": "%s:%s:%s" % (kind, pkg, date), "kind": "release",
                         "title": "%s: %s, %d upload%s after %s" % (name, pkg, len(versions),
                                                                   "" if len(versions) == 1 else "s", date),
                         "body": "\n".join(lines)[:BODY_LIMIT]})
    return findings, checked


NVD_API = "https://services.nvd.nist.gov/rest/json/cves/2.0?keywordSearch=%s"


def check_cves():
    """The rows "cve <word> <date> <port>" of upstream.conf: the CVEs of NVD that name
    <word> and were published after <date> (a library with no upstream any more, whose
    fixes we take from the distributions)."""
    findings, checked = [], set()
    for r in conf("upstream.conf"):
        if r[0] != "cve" or len(r) < 4:
            continue
        word, date, port = r[1], r[2], r[3]
        try:
            data = json.loads(http(NVD_API % word))
        except Exception as e:  # noqa: BLE001
            warn("NVD %s: %s" % (word, e))
            continue
        checked.add("cve:%s:" % word)
        new = []
        for v in data.get("vulnerabilities", []):
            c = v.get("cve", {})
            if c.get("published", "")[:10] > date:
                desc = next((x["value"] for x in c.get("descriptions", []) if x.get("lang") == "en"), "")
                new.append((c.get("published", "")[:10], c.get("id", "?"), desc))
        if not new:
            continue
        new.sort(reverse=True)
        lines = ["CVEs of NVD that name `%s`, published after %s (newest first): `%s` of azsupport/ports "
                 "has this library." % (word, date, port), ""]
        for pub, cid, desc in new:
            lines.append("- [%s](https://nvd.nist.gov/vuln/detail/%s) %s: %s" % (
                cid, cid, pub, desc[:400].replace("\n", " ")))
        lines += ["", "After the review: a fix from a distribution (Gentoo, Debian, Fedora) into `files/` of `%s`, or "
                      "the packages that need it out; then set the date of `cve %s` in `freebsd/upstream.conf` to "
                      "the day of the review; the next check closes this issue." % (port, word)]
        findings.append({"key": "cve:%s:%s" % (word, date), "kind": "ports",
                         "title": "CVE: %s, %d new after %s" % (word, len(new), date),
                         "body": "\n".join(lines)})
    return findings, checked


def bundled_dists():
    """(name, version, port, distfile, sha256, where) of curl and the libraries it needs."""
    out = []
    if os.path.exists(os.path.join(ROOT, "freebsd", "curl.conf")):
        rows = conf("curl.conf")
        if rows:
            _target, version, url, sha = rows[-1][:4]
            out.append(("curl", version, "ftp/curl", url.rsplit("/", 1)[1], sha, "freebsd/curl.conf"))
    for name, version, port, _repo, distfile, sha, _url in curl_deps():
        out.append((name, version, port, distfile, sha, "freebsd/curl-deps.conf"))
    return out


def port_version(git, port):
    """DISTVERSION or PORTVERSION of the Makefile of a port (main), None when it is not plain."""
    text = run(["git", "show", "main:%s/Makefile" % port], cwd=git, check=False) or ""
    m = re.search(r"^(?:DISTVERSION|PORTVERSION)[ \t]*[?:]?=[ \t]*(\S+)", text, re.M)
    return m.group(1) if m else None


def check_distinfo(git):
    """A release file in the distinfo of the port that the bundle has not (not when
    the bundle is ahead of the port: brotli 1.2.1 before archivers/brotli took it)."""
    findings, checked = [], set()
    for name, version, port, distfile, sha, where in bundled_dists():
        text = run(["git", "show", "main:%s/distinfo" % port], cwd=git, check=False)
        if not text:
            continue  # gone: check_ports reports a followed port that moved away
        checked.add("dist:%s:" % port)
        dists = re.findall(r"^SHA256 \((.+)\) = ([0-9a-f]{64})$", text, re.M)
        if (distfile, sha) in dists:
            continue
        pv, bv = vkey(port_version(git, port)), vkey(version)
        if pv and bv and pv < bv:
            log("%s: the bundle (%s) is ahead of %s (%s)" % (name, version, port, port_version(git, port)))
            continue
        main_file = next((f for f, _s in dists if "testdata" not in f), dists[0][0] if dists else "?")
        lines = ["freebsd-ports `%s` has (distinfo of `main`):" % port, ""]
        lines += ["- `%s` SHA-256 `%s`" % (f, s) for f, s in dists]
        lines += ["", "Bundled: %s %s, `%s` SHA-256 `%s` (`%s`)." % (name, version, distfile, sha, where), "",
                  "To take it: in `%s` set the version, the release file and its SHA-256 as in the port, bring "
                  "a patch of `freebsd/curl/` up to date if there is one, then run the build test; the next check "
                  "closes this issue. Not wanted: close it." % where]
        findings.append({
            "key": "dist:%s:%s" % (port, hashlib.sha256(text.encode()).hexdigest()[:12]),
            "kind": "ports",
            "title": "FreeBSD ports: %s has %s (bundled: %s)" % (port, main_file.rsplit("/", 1)[-1], distfile.rsplit("/", 1)[-1]),
            "body": "\n".join(lines),
        })
    return findings, checked


def check_php_eol():
    """The end of security support of the branches we take from the php-src tags."""
    findings, checked = [], set()
    try:
        branches = json.loads(http(PHP_BRANCHES))
        ends = {b["branch"]: b.get("security_support_end") for b in branches}
    except Exception as e:
        warn("php.net branches: %s" % e)
        return findings, checked
    try:
        out = run(["git", "ls-remote", "--heads", REMI_SECURITY])
        remi = sorted(l.split("refs/heads/", 1)[1] for l in out.splitlines() if "refs/heads/" in l)
    except RuntimeError as e:
        warn("remicollet/php-src-security: %s" % e)
        remi = None
    today = datetime.date.today()
    for target, _url, ref, _port, _portrev in conf("targets.conf"):
        checked.add("php-eol:%s" % target)
        if not ref.startswith("latest-tag:") or not ends.get(target):
            continue  # from Remi's backports already, or php.net does not know it
        end = datetime.date.fromisoformat(ends[target][:10])
        left = (end - today).days
        if left > EOL_NOTICE_DAYS:
            continue
        branch = [b for b in (remi or []) if b.startswith("PHP-%s-security-backports" % target)]
        when = end.strftime("%d.%m.%Y")
        lines = [
            "PHP %s: security support %s %s ([php.net](https://www.php.net/supported-versions.php)). "
            "After it php-src has no more %s releases, and `freebsd/targets.conf` takes %s from the php-src tags "
            "(`%s`)." % (target, "ends on" if left >= 0 else "ended on", when, target, target, ref),
            "",
        ]
        if branch:
            lines.append("Remi Collet's backports have [`%s`](%s/tree/%s); 5.6, 7.4 and 8.1 come from his branches "
                         "already." % (branch[0], REMI_SECURITY, branch[0]))
        elif remi is None:
            lines.append("The branches of %s could not be read this time." % REMI_SECURITY)
        else:
            lines.append("Remi Collet's backports (%s) have no PHP-%s-security-backports branch yet; this issue "
                         "says so when one comes." % (REMI_SECURITY, target))
        lines += ["", "To switch: in `freebsd/targets.conf` the line `%s %s.git refs/heads/PHP-%s-security-backports "
                  "...` with the same port and portrev; the next check closes this issue." % (target, REMI_SECURITY, target)]
        title = "PHP %s: security support %s %s" % (target, "ends" if left >= 0 else "ended", when)
        if branch:
            title += ", Remi has %s" % branch[0]
        findings.append({"key": "php-eol:%s" % target, "kind": "eol", "title": title, "body": "\n".join(lines)})
    return findings, checked


def port_finding(git, port, rev, kept, commits, moved, base):
    lines = []
    if moved:
        lines += ["**%s was moved or removed** on %s: %s%s." % (
            port, moved[2] if len(moved) > 2 else "?", moved[3] if len(moved) > 3 else "",
            " (new place: `%s`)" % moved[1] if len(moved) > 1 and moved[1] else ""), ""]
    elif not commits:
        lines += ["**%s is gone** from freebsd-ports and MOVED does not say where." % port, ""]
    if commits:
        lines += ["FreeBSD ports commits to `%s` after `%s` that change patches or the build "
                  "(newest first):" % (port, rev), ""]
        for sha, date, subject, files, patches, make in commits:
            short = [f[len(port) + 1:] if f.startswith(port + "/") else f for f in files]
            lines.append("- [`%s`](%s/commit/%s) %s %s (%s)" % (
                sha[:12], PORTS_URL, sha, date, subject.replace("|", "\\|"), ", ".join(short)))
        lines.append("")
        for sha, date, subject, files, patches, make in commits:
            if not (patches or make):
                continue
            diff = run(["git", "show", "--format=", sha, "--", *(patches or []),
                        *( [port + "/Makefile"] if make else [])], cwd=git)
            diff = diff.splitlines()
            more = len(diff) - 200
            lines += ["<details><summary><code>%s</code> %s</summary>" % (sha[:12], subject), "",
                      "```diff"] + diff[:200] + (["... %d more lines" % more] if more > 0 else []) + \
                     ["```", "", "</details>", ""]
    if not base and commits:
        lines += ["The reviewed revision `%s` is older than the fetched history, so these are all "
                  "commits of that time." % rev, ""]
    newest = commits[0][0][:12] if commits else "<new revision>"
    if kept == KEPT_BUNDLE % PORTS_CONF["deps.conf"]:
        lines += ["After the review, in azsupport/ports: take what /usr/local/az needs (patches of the port for "
                  "a take line into `az/az/files/deps/<name>-<version>/`, of multimedia/ffmpeg into "
                  "`multimedia/ffmpeg/files/ffmpeg/` and of the ImageMagick ports into `graphics/ImageMagick6/files/` "
                  "and `graphics/ImageMagick7/files/` when they are not the port's own), then move the ports commit "
                  "of `az/az/files/deps.conf` to `%s` (the ports of all the libraries, FFmpeg and ImageMagick move "
                  "with it), then %s The next check closes this issue." % (newest, PORTS_STEPS % PORTS_BUILD)]
    elif "of azsupport/ports" in kept:
        lines += ["After the review: in azsupport/ports the port named there as it should be with this (its own "
                  "patches: drop those the official port has now), then set the reviewed revision (%s) of `%s` to "
                  "`%s`; the next check closes this issue." % (kept, port, newest)]
    else:
        lines += ["After the review: take what we need into `freebsd/pecl/` (or `freebsd/patches/<target>/` "
                  "for lang ports), then set the reviewed revision (%s) of `%s` to `%s`; the next check "
                  "closes this issue." % (kept, port, newest)]
    body = "\n".join(lines)
    if len(body) > BODY_LIMIT:
        body = body[:BODY_LIMIT] + "\n\n... (cut, see the commits above)"
    what = "%d commit%s to review" % (len(commits), "" if len(commits) == 1 else "s") if commits else "moved away"
    return {
        "key": "ports:%s:%s" % (port, rev),
        "kind": "ports",
        "title": "FreeBSD ports: %s, %s after %s" % (port, what, rev[:12]),
        "body": body,
    }


class Issues:
    """The issues of this check (label "upstream"), found by the mark in the body."""

    def __init__(self, repo):
        self.repo, self.known = repo, {}
        out = run(["gh", "api", "--paginate",
                   "repos/%s/issues?state=all&labels=upstream&per_page=100" % repo,
                   "--jq", ".[] | select(.pull_request == null) | {number, state, title, body} | tojson"])
        for line in out.splitlines():
            issue = json.loads(line)
            m = re.search(r"<!-- upstream-check: (\S+) -->", issue.get("body") or "")
            if m:
                self.known[m.group(1)] = issue
        for name, color, desc in (("upstream", "0e8a16", "Found by tools/upstream-check.py"),
                                  ("release", "1d76db", "A newer release of a bundled extension"),
                                  ("ports", "d93f0b", "FreeBSD ports changes to review"),
                                  ("eol", "b60205", "End of upstream support of a PHP branch we build")):
            ok(["gh", "api", "repos/%s/labels" % repo, "-f", "name=" + name,
                "-f", "color=" + color, "-f", "description=" + desc])

    def api(self, method, path, payload):
        run(["gh", "api", "-X", method, "repos/%s/%s" % (self.repo, path), "--input", "-"],
            data=json.dumps(payload))

    def sync(self, findings, checked):
        owner = self.repo.split("/")[0]
        keys = set()
        for f in findings:
            keys.add(f["key"])
            body = "%s\n\ncc @%s\n\n%s" % (f["body"], owner, MARK % f["key"])
            issue = self.known.get(f["key"])
            if issue is None:
                self.api("POST", "issues", {"title": f["title"], "body": body,
                                            "labels": ["upstream", f["kind"]]})
                print("opened: %s" % f["title"])
            elif issue["state"] == "open" and (issue["body"] != body or issue["title"] != f["title"]):
                self.api("PATCH", "issues/%d" % issue["number"], {"title": f["title"], "body": body})
                print("updated #%d: %s" % (issue["number"], f["title"]))
        for key, issue in self.known.items():
            if issue["state"] != "open" or key in keys:
                continue
            if not any(key.startswith(prefix) for prefix in checked):
                continue  # its source could not be checked this time: leave it
            self.api("POST", "issues/%d/comments" % issue["number"],
                     {"body": "The check finds nothing for this any more: freebsd/pecl.conf or the "
                              "reviewed revision has moved on, or a newer release has its own issue."})
            self.api("PATCH", "issues/%d" % issue["number"], {"state": "closed", "state_reason": "completed"})
            print("closed #%d: %s" % (issue["number"], issue["title"]))


def main():
    global PORTS_DIR
    ap = argparse.ArgumentParser(description="Releases of the bundled PECL extensions and FreeBSD ports changes.")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    ap.add_argument("--workdir")
    ap.add_argument("--days", type=int, default=180)
    ap.add_argument("--ports", default=PORTS_DIR,
                    help="a checkout of azsupport/ports, for the conf files of the bundles (default: ports/ here)")
    args = ap.parse_args()
    PORTS_DIR = os.path.abspath(args.ports)
    if not all(os.path.exists(conf_file(c)) for c in PORTS_CONF):
        warn("no conf files of the bundles in %s (a checkout of azsupport/ports): az, FFmpeg and ImageMagick "
             "are not checked this time" % PORTS_DIR)
    if not args.dry_run and not args.repo:
        ap.error("--repo (or $GITHUB_REPOSITORY) is needed unless --dry-run")
    workdir = args.workdir or tempfile.mkdtemp(prefix="upstream-check-")
    os.makedirs(workdir, exist_ok=True)

    issues = None
    if not args.dry_run:
        try:
            issues = Issues(args.repo)
        except RuntimeError as e:
            sys.exit("cannot use the issues of %s: %s\nIssues must be on: https://github.com/%s/settings, "
                     "Features, Issues." % (args.repo, e, args.repo))

    pins = {r[1]: r[2] for r in conf("upstream.conf") if r[0] == "pin"}
    findings, checked = check_releases(workdir, pins)
    more, checked_deps = check_deps_releases()
    findings += more
    checked |= checked_deps
    more, checked_ports = check_ports(workdir, args.days)
    findings += more
    checked |= checked_ports
    more, checked_eol = check_php_eol()
    findings += more
    checked |= checked_eol
    for check in (check_trees, check_github, check_debian, check_launchpad):
        more, checked_more = check()
        findings += more
        checked |= checked_more
    more, checked_cves = check_cves()
    findings += more
    checked |= checked_cves

    summary = ["- %s" % f["title"] for f in findings] or ["- nothing new"]
    print("\n".join(summary))
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("### Upstream check\n\n%s\n" % "\n".join(summary))
    if args.dry_run:
        for f in findings:
            print("\n==== %s  [%s]\n%s" % (f["title"], f["key"], f["body"]))
        return
    issues.sync(findings, checked)


if __name__ == "__main__":
    main()
