#!/usr/bin/env python3
"""gentoo-fetch.py - the history of package directories of gentoo/gentoo, with
what it removed, and the patch sets their ebuilds download.

Gentoo keeps the patches of a package in its files/ and in patch sets that the
ebuilds download (gcc, perl, python, apache, mariadb ...), and drops both with
the versions they were for: a fix for an older version, or for a branch Gentoo
no longer has (PHP 7.4, 8.1, ImageMagick 6), is then only in the history of the
tree, and the patch set only on the mirrors of Gentoo (distfiles.gentoo.org) or
the space of a developer (dev.gentoo.org), which the sandbox of Claude Code
cannot reach. For each directory asked for (cat/pkg, also one removed from the
tree), from a full clone of gentoo/gentoo (the GitHub mirror of the tree):

  log.txt        its whole history: one block per commit (hash, date, author,
                 subject) with the files it added, changed and deleted
  recent.md      its commits after --since
  removed/<date>_<commit>/<file>
                 every file a commit deleted (ebuilds of a version, patches of
                 files/), as it was before that commit
  removed.tsv    the same as a list: date, commit, file, subject
  patchsets/<distfile>/
                 the patch sets the ebuilds downloaded, now or before: the DIST
                 files of its Manifest, current and past, whose names say patch,
                 patchset or gentoo, unpacked (each file up to FILE_LIMIT)
  patchsets.txt  each such DIST file: where it was taken from, or why it is missing

and report.md for all of them (the summary of the run). With --push the tree goes
into the branch runs of azsupport/azsupport, distro/gentoo/<YYYY-MM-DD>/ (UTC),
with the report as <run id>.md there, committed and pushed with the token
RUNS_TOKEN as tools/runs-report.sh does (a refused push is made again on the new
tip).

Usage: python3 -I tools/gentoo-fetch.py --out DIR [--since YYYY-MM-DD] [--report FILE]
                                        [--repo PATH] [--push] CAT/PKG...
  --out     where the tree is written (empty or new)
  --since   recent.md: the commits after this day (default: 7 days ago)
  --report  the summary in Markdown (also written as DIR/report.md)
  --repo    a clone of gentoo/gentoo to read instead of cloning one (a test)
  --push    commit the tree into azsupport/azsupport (branch runs); RUNS_REMOTE
            (a path or URL) instead, for a test
"""

import argparse
import bz2
import datetime
import gzip
import hashlib
import io
import lzma
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

UA = "gentoo-fetch (azsupport/php-src)"
GENTOO = "https://github.com/gentoo/gentoo.git"
MIRROR = "https://distfiles.gentoo.org/distfiles"
DEVSPACE = "https://dev.gentoo.org/~%s"
RUNS_URL = "https://x-access-token:%s@github.com/azsupport/azsupport.git"
RUNS_DIR = "distro/gentoo"
FILE_LIMIT = 4 * 1024 * 1024          # a bigger file of a patch set is left out (named in patchsets.txt)
DIST_LIMIT = 40 * 1024 * 1024         # a bigger DIST file is not downloaded
PATCHSET = re.compile(r"(?i)(patch|gentoo)")
MAX_DEVS = 4                          # developer spaces tried for a DIST file not on the mirrors
DIRNAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+_.-]*/[A-Za-z0-9][A-Za-z0-9+_.-]*$")
SEP = "\x1e"


def log(msg):
    print(msg, flush=True)


def warn(msg):
    print("::warning title=gentoo-fetch::%s" % msg, flush=True)


def git(repo, *args, data=None, check=True):
    r = subprocess.run(("git", "-C", repo) + args, input=data, capture_output=True)
    if check and r.returncode:
        raise RuntimeError("git %s: %s" % (args[0], r.stderr.decode("utf-8", "replace").strip()[-500:]))
    return r.stdout


def get(url, tries=2, timeout=30):
    """The body of url, or None when it is not there (403, 404, 410) or the host
    does not answer."""
    err = None
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            if e.code in (403, 404, 410):
                return None
            err = e
        except Exception as e:  # noqa: BLE001 - network: try again
            err = e
        time.sleep(2 * (i + 1))
    log("  %s: %s" % (url, err))
    return None


def history(repo, dirs):
    """{dir: [(sha, date, author, subject, [(status, path)])]} for all of dirs, newest
    first, in one walk of the history."""
    out = git(repo, "log", "--no-renames", "--format=%x1e%H%x09%cs%x09%an%x09%s", "--name-status",
              "--", *dirs)
    res = {d: [] for d in dirs}
    for block in out.decode("utf-8", "replace").split(SEP)[1:]:
        lines = block.strip("\n").split("\n")
        sha, date, author, subject = (lines[0].split("\t", 3) + ["", "", ""])[:4]
        files = [tuple(x.split("\t", 1)) for x in lines[1:] if "\t" in x]
        for d in dirs:
            mine = [(s, p) for s, p in files if p.startswith(d + "/")]
            if mine:
                res[d].append((sha, date, author, subject, mine))
    return res


def dists(repo, dirs):
    """{dir: {name: size}}: every DIST line the Manifest of each dir ever had."""
    manifests = ["%s/Manifest" % d for d in dirs]
    out = git(repo, "log", "-p", "--no-renames", "--format=%x1e", "--", *manifests).decode("utf-8", "replace")
    res = {d: {} for d in dirs}
    cur = None
    for line in out.split("\n"):
        if line.startswith("diff --git a/"):
            path = line[len("diff --git a/"):].split(" b/", 1)[0]
            cur = path[:-len("/Manifest")] if path.endswith("/Manifest") else None
            continue
        if cur in res and line[:6] in ("+DIST ", "-DIST ", " DIST "):
            f = line[1:].split()
            if len(f) >= 3 and f[2].isdigit():
                res[cur][f[1]] = int(f[2])
    for d in dirs:  # the current Manifest (also what a shallow clone has)
        r = subprocess.run(("git", "-C", repo, "show", "HEAD:%s/Manifest" % d), capture_output=True)
        for line in r.stdout.decode("utf-8", "replace").splitlines():
            f = line.split()
            if len(f) >= 3 and f[0] == "DIST" and f[2].isdigit():
                res[d][f[1]] = int(f[2])
    return res


def safe_rel(path):
    parts = [p for p in path.split("/") if p not in ("", ".", "..")]
    return "/".join(parts)


def unpack(name, raw, dest, listing):
    """Unpack a DIST file into dest: a tar archive file by file, a single
    (compressed) patch as it is."""
    os.makedirs(dest, exist_ok=True)
    low = name.lower()
    tar = None
    if re.search(r"\.(tar(\.(gz|bz2|xz|lzma))?|tgz|tbz2|txz)$", low):
        try:
            tar = tarfile.open(fileobj=io.BytesIO(raw), mode="r:*")
        except tarfile.TarError as e:
            listing.append("  not a tar archive: %s" % e)
    elif re.search(r"\.tar\.zst$", low):
        r = subprocess.run(("tar", "--zstd", "-tf", "-"), input=raw, capture_output=True)
        if r.returncode == 0:
            tmp = tempfile.mkdtemp()
            subprocess.run(("tar", "--zstd", "-xf", "-", "-C", tmp), input=raw, capture_output=True)
            buf = io.BytesIO()
            with tarfile.open(fileobj=buf, mode="w") as t:
                t.add(tmp, arcname=".")
            shutil.rmtree(tmp, ignore_errors=True)
            buf.seek(0)
            tar = tarfile.open(fileobj=buf, mode="r:")
    if tar is not None:
        n = 0
        for m in tar.getmembers():
            if not m.isfile():
                continue
            rel = safe_rel(m.name)
            if not rel:
                continue
            if m.size > FILE_LIMIT:
                listing.append("  left out (%d bytes): %s" % (m.size, rel))
                continue
            data = tar.extractfile(m).read()
            p = os.path.join(dest, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "wb") as f:
                f.write(data)
            n += 1
        listing.append("  %d files" % n)
        return
    data, base = raw, name
    for ext, mod in ((".xz", lzma), (".lzma", lzma), (".bz2", bz2), (".gz", gzip)):
        if low.endswith(ext):
            try:
                data, base = mod.decompress(raw), name[: -len(ext)]
            except Exception:  # noqa: BLE001 - keep it as it is
                pass
            break
    if len(data) > FILE_LIMIT:
        listing.append("  left out (%d bytes)" % len(data))
        return
    with open(os.path.join(dest, safe_rel(base) or "file"), "wb") as f:
        f.write(data)
    listing.append("  1 file")


def mirror_url(name):
    """The address of a distfile on the mirrors of Gentoo: metadata/layout.conf of
    the tree, filename-hash BLAKE2B 8 (the first 8 bits of the hash of the name)."""
    return "%s/%s/%s" % (MIRROR, hashlib.blake2b(name.encode()).hexdigest()[:2], name)


def fetch_dist(name, d, devs):
    """(data, url) of a DIST file, or (None, the addresses tried): the mirrors of
    Gentoo, then the spaces of the developers the ebuilds name (dev.gentoo.org)."""
    cat, pkg = d.split("/", 1)
    tried = [mirror_url(name), "%s/%s" % (MIRROR, name)]
    for dev in sorted(devs)[:MAX_DEVS]:
        base = DEVSPACE % dev
        tried += ["%s/distfiles/%s/%s/%s" % (base, cat, pkg, name), "%s/distfiles/%s" % (base, name)]
    for url in tried:
        data = get(url)
        if data is not None:
            return data, url
    return None, tried


def write(path, data):
    if os.path.dirname(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", required=True)
    ap.add_argument("--since", default="")
    ap.add_argument("--report")
    ap.add_argument("--repo")
    ap.add_argument("--push", action="store_true")
    ap.add_argument("--skip-dist", default="", help="a regular expression: DIST files not to download")
    ap.add_argument("dirs", nargs="*")
    a = ap.parse_args()

    dirs, bad = [], []
    for d in a.dirs:
        d = d.strip().strip("/")
        if not d:
            continue
        (dirs if DIRNAME.match(d) else bad).append(d)
    dirs = sorted(set(dirs))
    if bad:
        warn("not a cat/pkg directory, left out: %s" % " ".join(bad))
    if not dirs:
        log("no directories")
        return 2
    since = a.since or (datetime.date.today() - datetime.timedelta(days=7)).isoformat()
    day = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    run = os.environ.get("GITHUB_RUN_ID", "0")
    os.makedirs(a.out, exist_ok=True)

    work = None
    repo = a.repo
    if not repo:
        work = tempfile.mkdtemp()
        repo = os.path.join(work, "gentoo")
        t = time.time()
        log("cloning %s" % GENTOO)
        subprocess.run(("git", "clone", "-q", "--no-checkout", GENTOO, repo), check=True)
        log("cloned in %ds" % (time.time() - t))
    head = git(repo, "log", "-1", "--format=%H %cI").decode().strip()
    log("gentoo/gentoo at %s" % head)

    t = time.time()
    hist = history(repo, dirs)
    log("history of %d directories in %ds" % (len(dirs), time.time() - t))
    t = time.time()
    dist = dists(repo, dirs)
    log("DIST files of the Manifests in %ds" % (time.time() - t))

    rows, failed = [], []
    for d in dirs:
        base = os.path.join(a.out, d)
        commits = hist[d]
        if not commits:
            failed.append(d)
            log("%s: no history" % d)
            continue
        os.makedirs(base, exist_ok=True)
        # log.txt
        lines = []
        for sha, date, author, subject, files in commits:
            lines.append("%s %s %s: %s" % (sha, date, author, subject))
            lines += ["    %s %s" % (s, p[len(d) + 1:]) for s, p in files]
        write(os.path.join(base, "log.txt"), ("\n".join(lines) + "\n").encode())
        recent = [c for c in commits if c[1] > since]
        rl = ["# %s: commits after %s" % (d, since), ""]
        for sha, date, author, subject, files in recent:
            rl.append("- [`%s`](https://github.com/gentoo/gentoo/commit/%s) %s %s: %s"
                      % (sha[:12], sha, date, author, subject.replace("|", "\\|")))
            rl += ["  - %s `%s`" % (s, p[len(d) + 1:]) for s, p in files]
        write(os.path.join(base, "recent.md"), ("\n".join(rl) + "\n").encode())
        # removed files, as they were before the commit that deleted them
        reqs = []
        for sha, date, author, subject, files in commits:
            for s, p in files:
                if s == "D":
                    reqs.append((sha, date, subject, p))
        tsv = []
        if reqs:
            data = "".join("%s^:%s\n" % (sha, p) for sha, _, _, p in reqs).encode()
            out = git(repo, "cat-file", "--batch", data=data)
            pos = 0
            for sha, date, subject, p in reqs:
                nl = out.index(b"\n", pos)
                header = out[pos:nl].decode("utf-8", "replace").split()
                pos = nl + 1
                if len(header) == 3 and header[1] == "blob":
                    size = int(header[2])
                    blob = out[pos:pos + size]
                    pos += size + 1
                    rel = "removed/%s_%s/%s" % (date, sha[:10], safe_rel(p[len(d) + 1:]))
                    write(os.path.join(base, rel), blob)
                    tsv.append("%s\t%s\t%s\t%s" % (date, sha, p[len(d) + 1:], subject))
                else:
                    tsv.append("%s\t%s\t%s\t(missing: %s)" % (date, sha, p[len(d) + 1:], " ".join(header)))
        write(os.path.join(base, "removed.tsv"), ("\n".join(tsv) + ("\n" if tsv else "")).encode())
        # the developers whose space the ebuilds name (patch sets not on the mirrors)
        devs = set()
        texts = [git(repo, "show", "HEAD:%s/%s" % (d, n), check=False).decode("utf-8", "replace")
                 for n in git(repo, "ls-tree", "--name-only", "HEAD", d + "/", check=False).decode().split()
                 if n.endswith(".ebuild")]
        rdir = os.path.join(base, "removed")
        for root, _, names in os.walk(rdir):
            for n in names:
                if n.endswith(".ebuild"):
                    texts.append(open(os.path.join(root, n), encoding="utf-8", errors="replace").read())
        for txt in texts:
            devs.update(re.findall(r"dev\.gentoo\.org/~([a-z0-9_-]+)", txt))
            devs.update(re.findall(r"""PATCH_DEV\s*=\s*["']?([a-z0-9_-]+)""", txt))
        # patch sets
        pl = []
        got = miss = 0
        for name, size in sorted(dist[d].items()):
            if not PATCHSET.search(name):
                continue
            if a.skip_dist and re.search(a.skip_dist, name):
                pl.append("%s: skipped (--skip-dist)" % name)
                continue
            if size > DIST_LIMIT:
                pl.append("%s: %d bytes, not downloaded" % (name, size))
                continue
            data, where = fetch_dist(name, d, devs)
            if data is None:
                miss += 1
                pl.append("%s: missing (tried %s)" % (name, ", ".join(where)))
                continue
            got += 1
            pl.append("%s: %s" % (name, where))
            unpack(name, data, os.path.join(base, "patchsets", safe_rel(name)), pl)
        write(os.path.join(base, "patchsets.txt"), ("\n".join(pl) + ("\n" if pl else "")).encode())
        rows.append((d, len(commits), len(recent), len(reqs), got, miss))
        log("%s: %d commits, %d after %s, %d removed files, %d patch sets (%d missing)"
            % (d, len(commits), len(recent), since, len(reqs), got, miss))

    rep = ["### Gentoo fetch", "",
           "gentoo/gentoo at `%s`; commits after %s in recent.md of each directory." % (head, since), "",
           "| directory | commits | after %s | removed files | patch sets | missing |" % since,
           "|---|---|---|---|---|---|"]
    rep += ["| %s | %d | %d | %d | %d | %d |" % r for r in rows]
    if failed:
        rep += ["", "No history at all (no such directory in gentoo/gentoo, ever): %s" % ", ".join(failed)]
    text = "\n".join(rep) + "\n"
    write(os.path.join(a.out, "report.md"), text.encode())
    if a.report:
        write(a.report, text.encode())
    if work:
        shutil.rmtree(work, ignore_errors=True)
    ok = True
    if a.push:
        ok = push(a.out, day, dirs, run)
    return 0 if ok else 1


def push(out, day, dirs, run):
    """Commit <out> into the branch runs of azsupport/azsupport, RUNS_DIR/<day>/."""
    remote = os.environ.get("RUNS_REMOTE") or (RUNS_URL % os.environ["RUNS_TOKEN"]
                                               if os.environ.get("RUNS_TOKEN") else None)
    if not remote:
        warn("RUNS_TOKEN is not set: nothing pushed")
        return False
    target = "%s/%s" % (RUNS_DIR, day)

    def g(*args, cwd=None, check=True):
        r = subprocess.run(("git",) + args, cwd=cwd, capture_output=True, text=True)
        if check and r.returncode:
            raise RuntimeError("git %s: %s" % (args[0], re.sub(r"x-access-token:[^@]*@", "x-access-token:***@",
                                                             (r.stderr or r.stdout).strip())[-500:]))
        return r

    for attempt in range(1, 7):
        work = tempfile.mkdtemp()
        try:
            repo = os.path.join(work, "r")
            g("clone", "-q", "--depth", "1", "--filter=blob:none", "--sparse", "--branch", "runs",
              "--single-branch", remote, repo)
            g("sparse-checkout", "set", target, cwd=repo)
            dst = os.path.join(repo, target)
            os.makedirs(dst, exist_ok=True)
            for name in sorted(os.listdir(out)):
                src = os.path.join(out, name)
                if name == "report.md":
                    shutil.copyfile(src, os.path.join(dst, "%s.md" % run))
                    continue
                for pkg in sorted(os.listdir(src)):
                    p = os.path.join(dst, name, pkg)
                    if os.path.exists(p):
                        shutil.rmtree(p)
                    shutil.copytree(os.path.join(src, pkg), p)
            g("add", "-A", target, cwd=repo)
            if not g("status", "--porcelain", cwd=repo).stdout.strip():
                log("runs: nothing new to commit")
                return True
            g("-c", "user.name=github-actions[bot]",
              "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
              "commit", "-q", "-m", "gentoo-fetch: %d directories (run %s)" % (len(dirs), run), cwd=repo)
            r = g("push", "-q", "origin", "HEAD:runs", cwd=repo, check=False)
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


if __name__ == "__main__":
    sys.exit(main())
