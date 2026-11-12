#!/usr/bin/env python3
"""arch-fetch.py - the packaging of Arch Linux packages: PKGBUILD, patches, history.

For each package asked for, the git repository of its packaging on
gitlab.archlinux.org (archlinux/packaging/packages/<pkgbase>), which holds the
whole history of the package, the years of svn too. A name that is no pkgbase is
looked up as a pkgname in the package search of archlinux.org and its pkgbase is
taken (the report says so). Of every package, without running anything of it:

  HEAD/         the files of the repository now (PKGBUILD, .SRCINFO, the patches,
                the other files; keys/ and a file bigger than FILE_LIMIT left out)
  HEAD-url/     the patches the PKGBUILD of now fetches from elsewhere: the entries
                of source in .SRCINFO that look like a patch (*.patch, *.diff,
                /commit/, /patch/ ...), downloaded as they are
  history/      every version of every patch file the repository ever held
                (*.patch, *.diff, compressed ones, files under a patches/
                directory), once per content: <path, / as __>@<blob id, 12 digits>
  pkgbuild.log  the history of PKGBUILD (git log -p, newest first)
  log.md        every commit: date, id, pkgver-pkgrel of its PKGBUILD, subject, the
                patch files it added (A), changed (M) or removed (D)
  index.md      pkgbase, version now, the patches now (local and fetched), the
                versions of history/ with the versions of the package that had them

ARCH_GITLAB (a format with %s for the path) clones from elsewhere, for a test.
--url URL fetches a file of anywhere into _urls/ (a patch of a host the sandbox of
Claude Code cannot reach), named after the URL.

With --push the tree goes into the branch runs of azsupport/azsupport, under
distro/arch/<YYYY-MM-DD>/ (UTC), committed and pushed with the token RUNS_TOKEN as
tools/runs-report.sh does; a refused push is made again on the new tip.

Usage: python3 tools/arch-fetch.py --out DIR [--report FILE] [--push]
                                   [--url URL]... PACKAGE...
"""

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

UA = "arch-fetch (azsupport/php-src)"
GITLAB = os.environ.get("ARCH_GITLAB") or "https://gitlab.archlinux.org/archlinux/packaging/packages/%s.git"
SEARCH = "https://archlinux.org/packages/search/json/?name=%s"
FILE_LIMIT = 4 * 1024 * 1024
URL_LIMIT = 8 * 1024 * 1024
NAME = re.compile(r"^[A-Za-z0-9@_+][A-Za-z0-9@._+-]*$")
PATCHLIKE = re.compile(r"(\.(patch|diff|patches)(\.(gz|xz|bz2|zst))?$)|(^|/)(patches|debian)/")
URL_PATCHLIKE = re.compile(r"(\.(patch|diff)(\.(gz|xz|bz2|zst))?([?#].*)?$)|/commit/|/commits/|/patch/|"
                           r"[?&;]a=commitdiff|/merge_requests/|/pull/|patch", re.I)
RUNS_URL = "https://x-access-token:%s@github.com/azsupport/azsupport.git"
RUNS_DIR = "distro/arch"

warnings = []


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def warn(msg):
    warnings.append(msg)
    print(("::warning title=arch-fetch::" if os.environ.get("GITHUB_ACTIONS") else "warning: ") + msg,
          file=sys.stderr, flush=True)


def get(url, limit, tries=3):
    """The body of url (bytes); None on 404/410."""
    err = None
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=120) as r:
                data = r.read(limit + 1)
                if len(data) > limit:
                    raise RuntimeError("bigger than %d bytes" % limit)
                return data
        except urllib.error.HTTPError as e:
            if e.code in (404, 410):
                return None
            err = e
        except Exception as e:  # noqa: BLE001
            err = e
        if i + 1 < tries:
            time.sleep(3 * (i + 1))
    raise RuntimeError("%s: %s" % (url, err))


GIT_ENV = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_ASKPASS="true")


def git(*args, cwd=None, check=True, inp=None, text=True):
    r = subprocess.run(("git",) + args, cwd=cwd, capture_output=True, text=text, input=inp, env=GIT_ENV)
    if check and r.returncode:
        err = r.stderr if text else r.stderr.decode("utf-8", "replace")
        raise RuntimeError("git %s: %s" % (args[0], re.sub(r"x-access-token:[^@]*@", "x-access-token:***@",
                                                         err.strip())[-500:]))
    return r


def project_path(name):
    """The path of a pkgbase on gitlab.archlinux.org (its rule: + is plus, tree is unix-tree)."""
    if name == "tree":
        return "unix-tree"
    p = name.replace("+", "plus")
    p = re.sub(r"[^a-zA-Z0-9_.-]", "-", p)
    p = re.sub(r"[_.-]{2,}", "-", p)
    return p


def pkgbase_of(name):
    """The pkgbase of a pkgname of the repositories (None if there is none)."""
    try:
        data = get(SEARCH % urllib.parse.quote(name), 4 * 1024 * 1024)
    except RuntimeError as e:
        warn("package search of %s: %s" % (name, e))
        return None
    if not data:
        return None
    res = json.loads(data.decode("utf-8")).get("results") or []
    bases = sorted({r.get("pkgbase") for r in res if r.get("pkgbase")})
    return bases[0] if bases else None


def clone(name, dest):
    url = GITLAB % project_path(name)
    for i in range(3):
        r = git("clone", "-q", "--bare", url, dest, check=False)
        if r.returncode == 0:
            return True
        if re.search(r"not found|could not read|Authentication|403|404", r.stderr, re.I) and i:
            break
        shutil.rmtree(dest, ignore_errors=True)
        time.sleep(3 * (i + 1))
    return False


def blob_batch(repo, specs):
    """The contents (bytes, or None) of the objects named by specs, by git cat-file --batch."""
    if not specs:
        return []
    inp = ("\n".join(specs) + "\n").encode()
    r = subprocess.run(("git", "cat-file", "--batch"), cwd=repo, input=inp, capture_output=True)
    out, pos, res = r.stdout, 0, []
    for _ in specs:
        nl = out.index(b"\n", pos)
        head = out[pos:nl].decode("utf-8", "replace").split()
        pos = nl + 1
        if len(head) < 3 or head[-1] == "missing":
            res.append(None)
            continue
        size = int(head[2])
        res.append(out[pos:pos + size])
        pos += size + 1
    return res


def pkgver_of(text):
    """pkgver-pkgrel (epoch:) of the text of a PKGBUILD, as written there."""
    if text is None:
        return "?"
    t = text.decode("utf-8", "replace")
    vals = {}
    for k in ("epoch", "pkgver", "pkgrel", "_pkgver", "_basever", "_ver"):
        m = re.search(r"^%s=([^\n#]*)" % k, t, re.M)
        if m:
            vals[k] = m.group(1).strip().strip("'\"")
    v = vals.get("pkgver", "?")
    for k in ("_pkgver", "_basever", "_ver"):
        if "$" in v and k in vals:
            v = v.replace("${%s}" % k, vals[k]).replace("$%s" % k, vals[k])
    v = "%s-%s" % (v, vals.get("pkgrel", "?"))
    if vals.get("epoch"):
        v = "%s:%s" % (vals["epoch"], v)
    return v


def srcinfo_sources(text):
    """The source entries of a .SRCINFO (all architectures)."""
    out = []
    for line in text.decode("utf-8", "replace").splitlines():
        m = re.match(r"^\s*source(?:_\w+)?\s*=\s*(.+?)\s*$", line)
        if m and m.group(1) not in out:
            out.append(m.group(1))
    return out


def safe(name):
    return re.sub(r"[^A-Za-z0-9._@+-]", "_", name)[:180]


def fetch_package(name, out):
    """Write the tree of one package into out/<pkgbase>/; (pkgbase, summary) or raise."""
    work = tempfile.mkdtemp()
    try:
        repo = os.path.join(work, "repo.git")
        base, note = name, ""
        if not clone(name, repo):
            shutil.rmtree(repo, ignore_errors=True)
            pb = pkgbase_of(name)
            if not pb or pb == name or not clone(pb, repo):
                raise RuntimeError("no packaging repository (%s)" % (
                    "pkgbase %s" % pb if pb and pb != name else "no package of that name"))
            base, note = pb, "pkgname %s, pkgbase %s" % (name, pb)
        dest = os.path.join(out, base)
        if os.path.exists(dest):
            return base, None
        os.makedirs(dest)

        # HEAD/
        head_files, left = [], []
        ls = git("ls-tree", "-r", "-l", "HEAD", cwd=repo).stdout.splitlines()
        entries = []
        for line in ls:
            meta, _, path = line.partition("\t")
            parts = meta.split()
            if len(parts) < 4 or parts[1] != "blob":
                continue
            size = int(parts[3]) if parts[3].isdigit() else 0
            if path.startswith("keys/") or size > FILE_LIMIT:
                left.append("%s (%s bytes)" % (path, parts[3]))
                continue
            entries.append((path, parts[2]))
        contents = blob_batch(repo, [b for _, b in entries])
        srcinfo = pkgbuild = None
        for (path, _), data in zip(entries, contents):
            if data is None:
                continue
            p = os.path.join(dest, "HEAD", path)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "wb") as f:
                f.write(data)
            head_files.append(path)
            if path == ".SRCINFO":
                srcinfo = data
            elif path == "PKGBUILD":
                pkgbuild = data

        # HEAD-url/: the patches fetched by URL
        fetched, failed = [], []
        for entry in srcinfo_sources(srcinfo) if srcinfo else []:
            fname, sep, url = entry.partition("::")
            if not sep:
                url, fname = entry, entry.rstrip("/").split("/")[-1]
            url = re.sub(r"^git\+", "", url)
            if not re.match(r"^https?://", url) or not URL_PATCHLIKE.search(url + " " + fname):
                continue
            if re.search(r"\.(tar|tgz|zip|7z|gem|whl|jar)\b", fname, re.I) and not re.search(
                    r"\.(patch|diff)", fname, re.I):
                continue
            if url.startswith("https://") and re.search(r"\.git([#?].*)?$", url):
                continue
            try:
                data = get(url, URL_LIMIT)
            except RuntimeError as e:
                failed.append("%s: %s" % (url, e))
                continue
            if data is None:
                failed.append("%s: not found" % url)
                continue
            os.makedirs(os.path.join(dest, "HEAD-url"), exist_ok=True)
            with open(os.path.join(dest, "HEAD-url", safe(fname)), "wb") as f:
                f.write(data)
            fetched.append((safe(fname), url))

        # the commits, oldest first: their PKGBUILD version and the patch files they touch
        raw = git("log", "--reverse", "--first-parent", "--no-renames", "--raw", "--no-abbrev",
                  "--format=%x01%H%x09%ad%x09%s", "--date=short", "HEAD", cwd=repo).stdout
        commits = []
        for chunk in raw.split("\x01")[1:]:
            lines = chunk.split("\n")
            h, d, s = (lines[0].split("\t", 2) + ["", ""])[:3]
            changes = []
            for line in lines[1:]:
                if not line.startswith(":"):
                    continue
                meta, _, path = line.partition("\t")
                m = meta.split()
                if len(m) >= 5:
                    changes.append((m[4][0], path, m[3]))
            commits.append((h, d, s, changes))
        vers = blob_batch(repo, ["%s:PKGBUILD" % c[0] for c in commits])
        state, seen_in = {}, {}
        rows = []
        for (h, d, s, changes), pb in zip(commits, vers):
            v = pkgver_of(pb)
            touched = []
            for st, path, blob in changes:
                if not PATCHLIKE.search(path):
                    continue
                touched.append("%s %s" % (st, path))
                if st == "D":
                    state.pop(path, None)
                else:
                    state[path] = blob
            for path, blob in state.items():
                vs = seen_in.setdefault((path, blob), [])
                if not vs or vs[-1] != v:
                    vs.append(v)
            rows.append((d, h[:12], v, s.replace("|", "\\|"), ", ".join(touched).replace("|", "\\|")))

        # history/
        hist = sorted(seen_in)
        datas = blob_batch(repo, [b for _, b in hist])
        for (path, blob), data in zip(hist, datas):
            if data is None:
                continue
            p = os.path.join(dest, "history", "%s@%s" % (path.replace("/", "__"), blob[:12]))
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "wb") as f:
                f.write(data)

        with open(os.path.join(dest, "log.md"), "w") as f:
            f.write("# %s: commits of its packaging (oldest first)\n\n" % base)
            f.write("| date | commit | version | subject | patch files |\n|---|---|---|---|---|\n")
            for r in rows:
                f.write("| %s | %s | %s | %s | %s |\n" % r)
        pl = git("log", "-p", "--first-parent", "--format=commit %H%nDate: %ad%n%n    %s%n", "--date=short",
                 "HEAD", "--", "PKGBUILD", cwd=repo, check=False).stdout
        with open(os.path.join(dest, "pkgbuild.log"), "w") as f:
            f.write(pl)

        now = pkgver_of(pkgbuild)
        cur = sorted(p for p in head_files if PATCHLIKE.search(p))
        lines = ["# %s (Arch Linux)" % base, "",
                 "- packaging: https://gitlab.archlinux.org/archlinux/packaging/packages/%s" % project_path(base),
                 "- version now: %s; commits: %d (%s to %s)" % (
                     now, len(commits), commits[0][1] if commits else "?", commits[-1][1] if commits else "?")]
        if note:
            lines.append("- asked as %s" % note)
        lines += ["", "## Patches now", ""]
        lines += ["- `HEAD/%s`" % p for p in cur] or ["- none in the repository"]
        lines += ["- `HEAD-url/%s` <- %s" % x for x in fetched]
        lines += ["- not fetched: %s" % x for x in failed]
        if srcinfo:
            lines += ["", "## Sources now (.SRCINFO)", ""] + ["- `%s`" % s for s in srcinfo_sources(srcinfo)]
        if left:
            lines += ["", "Left out of HEAD/: %s" % ", ".join(left)]
        lines += ["", "## Patch files of the history", "",
                  "| file | blob | versions of the package that had it |", "|---|---|---|"]
        for (path, blob) in hist:
            vs = seen_in[(path, blob)]
            shown = vs if len(vs) <= 6 else vs[:2] + ["…"] + vs[-3:]
            lines.append("| %s | `history/%s@%s` | %s |" % (path, path.replace("/", "__"), blob[:12],
                                                          ", ".join(shown)))
        with open(os.path.join(dest, "index.md"), "w") as f:
            f.write("\n".join(lines) + "\n")
        return base, (now, len(cur) + len(fetched), len(hist), len(commits), note)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def fetch_url(url, out):
    data = get(url, URL_LIMIT)
    if data is None:
        raise RuntimeError("not found")
    name = safe(re.sub(r"^https?://", "", url).replace("/", "_"))
    os.makedirs(os.path.join(out, "_urls"), exist_ok=True)
    with open(os.path.join(out, "_urls", name), "wb") as f:
        f.write(data)
    return name, len(data)


def push(out, day, what, run):
    """Commit <out> into the branch runs of azsupport/azsupport, RUNS_DIR/<day>/."""
    remote = os.environ.get("RUNS_REMOTE") or (RUNS_URL % os.environ["RUNS_TOKEN"]
                                               if os.environ.get("RUNS_TOKEN") else None)
    if not remote:
        warn("RUNS_TOKEN is not set: nothing pushed")
        return False
    target = "%s/%s" % (RUNS_DIR, day)
    for attempt in range(1, 7):
        work = tempfile.mkdtemp()
        try:
            repo = os.path.join(work, "r")
            git("clone", "-q", "--depth", "1", "--filter=blob:none", "--sparse", "--branch", "runs",
                "--single-branch", remote, repo)
            git("sparse-checkout", "set", target, cwd=repo)
            for d in sorted(os.listdir(out)):
                dst = os.path.join(repo, target, d)
                src = os.path.join(out, d)
                if os.path.isdir(src):
                    if d == "_urls":
                        os.makedirs(dst, exist_ok=True)
                        for fn in os.listdir(src):
                            shutil.copy2(os.path.join(src, fn), os.path.join(dst, fn))
                        continue
                    if os.path.exists(dst):
                        shutil.rmtree(dst)
                    shutil.copytree(src, dst)
            git("add", "-A", target, cwd=repo)
            if not git("status", "--porcelain", cwd=repo).stdout.strip():
                log("runs: nothing new to commit")
                return True
            git("-c", "user.name=github-actions[bot]",
                "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
                "commit", "-q", "-m", "arch-fetch: %s (run %s)" % (" ".join(what)[:200], run), cwd=repo)
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
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", required=True)
    ap.add_argument("--report")
    ap.add_argument("--push", action="store_true")
    ap.add_argument("--url", action="append", default=[])
    ap.add_argument("packages", nargs="*")
    a = ap.parse_args()

    asked = []
    for item in " ".join(a.packages).replace(",", " ").split():
        if not NAME.match(item):
            warn("not a package name: %r, left out" % item)
        elif item not in asked:
            asked.append(item)
    urls = [u for u in " ".join(a.url).split() if re.match(r"^https?://[^\s]+$", u)]
    if not asked and not urls:
        log("nothing asked")
        return 2
    os.makedirs(a.out, exist_ok=True)
    results, errors, got_urls = [], [], []
    for name in asked:
        log("%s ..." % name)
        try:
            base, summary = fetch_package(name, a.out)
            if summary is None:
                results.append((name, base, "(same as an earlier name)", "", "", "", ""))
            else:
                now, cur, hist, ncommits, note = summary
                results.append((name, base, now, cur, hist, ncommits, note))
        except Exception as e:  # noqa: BLE001
            errors.append("%s: %s" % (name, e))
    for url in urls:
        try:
            fn, size = fetch_url(url, a.out)
            got_urls.append((url, fn, size))
        except Exception as e:  # noqa: BLE001
            errors.append("%s: %s" % (url, e))
    for e in errors:
        warn(e)

    day = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    pushed = None
    if a.push and (results or got_urls):
        pushed = push(a.out, day, asked + ["%d urls" % len(got_urls)] if got_urls else asked,
                      os.environ.get("GITHUB_RUN_ID", "local"))
    rep = ["### Arch fetch", "", "Packages: `%s`%s." % (" ".join(asked), "; %d URLs" % len(urls) if urls else ""),
           ""]
    if pushed:
        rep += ["Pushed to the branch runs of azsupport/azsupport: `%s/%s/<pkgbase>/`." % (RUNS_DIR, day), ""]
    elif a.push:
        rep += ["**Not pushed** to azsupport/azsupport (see the warnings).", ""]
    rep += ["| asked | pkgbase | version now | patches now | patch versions in history | commits | note |",
            "|---|---|---|---|---|---|---|"]
    rep += ["| %s | %s | %s | %s | %s | %s | %s |" % r for r in results]
    if got_urls:
        rep += ["", "| URL | file in _urls/ | bytes |", "|---|---|---|"]
        rep += ["| %s | %s | %d |" % u for u in got_urls]
    if warnings:
        rep += ["", "Warnings:", ""] + ["- %s" % w for w in warnings]
    text = "\n".join(rep) + "\n"
    if a.report:
        with open(a.report, "w") as f:
            f.write(text)
    print(text)
    if not results and not got_urls:
        return 1
    return 0 if (pushed or not a.push) else 1


if __name__ == "__main__":
    sys.exit(main())
