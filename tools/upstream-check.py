#!/usr/bin/env python3
"""upstream-check.py - what the upstreams of this fork published since we looked.

Releases. For every extension in freebsd/pecl.conf: the release tags of its
repository and its PECL releases; for curl (freebsd/curl.conf) the tags of
github.com/curl/curl. A stable release newer than the bundled one
is reported for the targets whose PHP version it supports (package.xml of the
tag, else the PECL dependencies). A "pin" line in freebsd/upstream.conf keeps
an extension to one series. Pre-releases count only where the bundled version
is one (gmagick, memcache 3.0.8).

FreeBSD ports. For every "port" line in freebsd/upstream.conf and for
lang/<port> of freebsd/targets.conf (at its portrev): the freebsd-ports commits
after the reviewed revision that change files/ (the patches) or the Makefile
beyond its version lines, or that move the port away.

Every finding is one issue with the labels "upstream" and "release" or "ports",
marked in its body, so the next runs update that issue instead of opening
another one. An open issue whose finding is gone (pecl.conf has the version,
the reviewed revision moved on) is closed; a closed one stays closed, so
closing an issue is how to say "not wanted". Nothing is applied.

Usage: python3 tools/upstream-check.py [--dry-run] [--repo OWNER/NAME]
                                       [--workdir DIR] [--days N]
  --dry-run   print the findings, do not read or change issues
  --repo      repository of the issues (default: $GITHUB_REPOSITORY)
  --workdir   where the git clones go (default: a temporary directory)
  --days      freebsd-ports history to fetch (default 180); a reviewed revision
              older than that is reported, with all commits of these days
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORTS_URL = "https://github.com/freebsd/freebsd-ports"
PECL_REST = "https://pecl.php.net/rest/r"
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


def conf(name):
    """Rows of freebsd/<name>, without comments and blank lines."""
    with open(os.path.join(ROOT, "freebsd", name)) as f:
        rows = (line.split("#", 1)[0].split() for line in f)
        return [r for r in rows if r]


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


def tag_version(tag):
    """Version of a release tag: 6.3.0, v3.4.0, release-2.0.1, RELEASE_3_0_6, memcache-3.0.8,
    curl-8_23_0."""
    if tag.startswith("curl-"):
        tag = tag[len("curl-"):].replace("_", ".")
    if tag.startswith("RELEASE_"):
        tag = tag[len("RELEASE_"):].replace("_", ".")
    v = re.sub(r"^(v|release-|memcache-)", "", tag)
    return v if vkey(v) else None


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
                v = tag_version(tag)
                if v:
                    self.tags.setdefault(v, tag)
            self.sources += 1
        except RuntimeError as e:
            warn("%s: no tags from %s: %s" % (name, url, e))
        try:
            if name == "curl":
                raise RuntimeError("not a PECL package")
            xml = http("%s/%s/allreleases.xml" % (PECL_REST, name.lower()))
            for v, s in re.findall(r"<r>\s*<v>([^<]+)</v>\s*<s>([^<]+)</s>", xml):
                if vkey(v):
                    self.pecl[v.strip()] = s.strip()
            self.sources += 1
        except Exception as e:
            log("%s: no PECL releases: %s" % (name, e))

    def stable(self, v):
        if v in self.pecl:
            return self.pecl[v] == "stable"
        return vkey(v)[4] == 3

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
    findings, checked = [], set()
    for name, entries in rows.items():
        up = Upstream(name, entries[0][2], workdir)
        if not up.sources:
            continue
        checked.add("release:%s:" % name)
        news = {}
        for target, cur, _url in entries:
            v = newest_fitting(up, target, cur, pins.get(name))
            if v:
                news.setdefault(v, []).append((target, cur))
        for v, hits in sorted(news.items(), key=lambda x: vkey(x[0])):
            findings.append(release_finding(up, v, hits, pins.get(name)))
    return findings, checked


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
    if up.name == "curl":
        lines[2] = "It needs OpenSSL 3.0 or later, as the bundled curl does now."
        lines += [
            "",
            "To take it: in `freebsd/curl.conf` set version `%s`, the release tarball and its SHA-256 "
            "(the same as freebsd-ports `ftp/curl/distinfo` once the port has it), and bring "
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
    ports = [(r[1], r[2], "freebsd/upstream.conf") for r in conf("upstream.conf") if r[0] == "port"]
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
                                  ("ports", "d93f0b", "FreeBSD ports changes to review")):
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
    ap = argparse.ArgumentParser(description="Releases of the bundled PECL extensions and FreeBSD ports changes.")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    ap.add_argument("--workdir")
    ap.add_argument("--days", type=int, default=180)
    args = ap.parse_args()
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
    more, checked_ports = check_ports(workdir, args.days)
    findings += more
    checked |= checked_ports

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
