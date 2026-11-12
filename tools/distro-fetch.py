#!/usr/bin/env python3
"""distro-fetch.py - the specs and patches of RPM distributions, per dist-git branch.

For each package asked for, its dist-git repository of one source (SOURCES below):

  fedora         src.fedoraproject.org/rpms/<pkg>: rawhide, the fNN branches (the
                 maintained ones and those of releases at their end of life), the
                 EPEL branches (epel7 ... epel10.x), el5/el6 and the others
  centos-stream  gitlab.com/redhat/centos-stream/rpms/<pkg>: c9s, c10s (the sources
                 of RHEL 9 and 10) and c8s, with the branches of module streams
  centos         git.centos.org/rpms/<pkg>: c7, c8, c8s and their module streams
                 (c8-stream-7.4, c8s-stream-8.2 ...), the sources of RHEL 7 and 8
  almalinux      git.almalinux.org/rpms/<pkg>: a8, a9, a10 and their module
                 streams (a8-stream-7.4 ...): the current RHEL sources
  rocky          git.rockylinux.org/staging/rpms/<pkg>: r8, r9, r10 ...
  openela        github.com/openela-main/<pkg>: el8, el9, el10 and their streams

Of every branch: its spec, the other files of the package (patches, small sources;
the root of the repository, or SPECS/ and SOURCES/ of the layout of git.centos.org),
the head of its %changelog (the entries of the last CHANGELOG_YEARS years, at least
CHANGELOG_MIN of them; for a spec with %autochangelog the commit messages, which
rpmautospec makes the changelog of), the subjects of its last commits and
source.txt (the commit, Name, Version, Release, the Patch lines, the files). A
branch whose head is a retired package (dead.package) is taken at the commit
before the retirement, with its date and reason. Branches with the same files
are written once (index.md and source.txt name the others).

Layout of the output (--out DIR):

  DIR/<package>/<branch>/   source.txt  <name>.spec  changelog  commits.txt  files/

With --push the tree goes into the branch runs of azsupport/azsupport, under
distro/<source>/<YYYY-MM-DD>/ (UTC), with an index.md per package, committed and
pushed with the token RUNS_TOKEN as tools/runs-report.sh does; several runs may
push at the same time, so a refused push is made again on the new tip.

Usage: python3 tools/distro-fetch.py --source SOURCE --out DIR [--report FILE]
                                     [--branches REGEX] [--push] PACKAGE...
  --source    one of SOURCES
  --out       where the tree is written (empty or new)
  --report    a summary in Markdown (the job summary, the report of the run)
  --branches  only the branches whose whole name matches this regular expression
              (rawhide|f4[0-9]|epel.*); empty: every branch
  --push      commit the tree into azsupport/azsupport (branch runs); RUNS_REMOTE
              (a path or URL) instead, for a test
Environment: DISTRO_URL, a URL with %s for the package, instead of that of the
source (a test).
"""

import argparse
import datetime
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

SOURCES = {
    # name: (clone URL, commit URL, what it is)
    "fedora": ("https://src.fedoraproject.org/rpms/%s.git", "https://src.fedoraproject.org/rpms/%s/c/%s",
               "Fedora dist-git"),
    "centos-stream": ("https://gitlab.com/redhat/centos-stream/rpms/%s.git",
                      "https://gitlab.com/redhat/centos-stream/rpms/%s/-/commit/%s", "CentOS Stream"),
    "centos": ("https://git.centos.org/rpms/%s.git", "https://git.centos.org/rpms/%s/c/%s", "git.centos.org"),
    "almalinux": ("https://git.almalinux.org/rpms/%s.git", "https://git.almalinux.org/rpms/%s/commit/%s",
                  "AlmaLinux"),
    "rocky": ("https://git.rockylinux.org/staging/rpms/%s.git",
              "https://git.rockylinux.org/staging/rpms/%s/-/commit/%s", "Rocky Linux (staging)"),
    "openela": ("https://github.com/openela-main/%s.git", "https://github.com/openela-main/%s/commit/%s",
                "OpenELA"),
}
CHANGELOG_YEARS = 6
CHANGELOG_MIN = 10
CHANGELOG_MAX_LINES = 4000
COMMITS = 300
FILE_LIMIT = 4 * 1024 * 1024        # a bigger file is left out (named in source.txt)
SKIP = {".gitignore", ".gitattributes", "dead.package"}
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9+._-]*$")
RUNS_URL = "https://x-access-token:%s@github.com/azsupport/azsupport.git"
RUNS_DIR = "distro"

warnings = []


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def warn(msg):
    warnings.append(msg)
    print(("::warning title=distro-fetch::" if os.environ.get("GITHUB_ACTIONS") else "warning: ") + msg,
          file=sys.stderr, flush=True)


def git(*args, cwd=None, check=True, data=None, timeout=1800):
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GIT_ASKPASS="/bin/false", LC_ALL="C")
    r = subprocess.run(("git",) + args, cwd=cwd, capture_output=True, input=data, env=env, timeout=timeout)
    if check and r.returncode:
        err = (r.stderr or r.stdout).decode("utf-8", "replace").strip()
        raise RuntimeError("git %s: %s" % (args[0], re.sub(r"x-access-token:[^@]*@", "x-access-token:***@",
                                                            err)[-500:]))
    return r


def out(*args, cwd=None):
    return git(*args, cwd=cwd).stdout.decode("utf-8", "replace")


# ------------------------------------------------------------------ the spec
def expand(text, macros, depth=0):
    """The macros of an RPM spec expanded as far as a plain reading can: %{name},
    %name, %{?name}, %{?name:text}, %{!?name:text}; unknown ones stay."""
    if depth > 12 or "%" not in text:
        return text
    res, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c != "%" or i + 1 >= n:
            res.append(c)
            i += 1
            continue
        nxt = text[i + 1]
        if nxt == "%":
            res.append("%")
            i += 2
            continue
        if nxt == "{":
            level, j = 1, i + 2
            while j < n and level:
                if text[j] == "{":
                    level += 1
                elif text[j] == "}":
                    level -= 1
                j += 1
            body = text[i + 2:j - 1]
            i = j
            neg = body.startswith("!?")
            cond = neg or body.startswith("?")
            body = body[2:] if neg else (body[1:] if cond else body)
            name, sep, alt = body.partition(":")
            if cond:
                have = name in macros
                if neg:
                    res.append(expand(alt, macros, depth + 1) if (sep and not have) else "")
                elif sep:
                    res.append(expand(alt, macros, depth + 1) if have else "")
                else:
                    res.append(expand(macros[name], macros, depth + 1) if have else "")
            elif name in macros and not sep:
                res.append(expand(macros[name], macros, depth + 1))
            else:
                res.append("%{" + body + "}")
            continue
        m = re.match(r"[A-Za-z_]\w*", text[i + 1:])
        if m and m.group(0) in macros:
            res.append(expand(macros[m.group(0)], macros, depth + 1))
            i += 1 + len(m.group(0))
            continue
        res.append(c)
        i += 1
    return "".join(res)


def read_spec(text):
    """Name, Version, Release (expanded as far as a plain reading can), the Patch
    lines [(number, file)] and the %changelog text of a spec."""
    macros = {"dist": "", "autorelease": "%autorelease", "_sourcedir": ".", "_bindir": "/usr/bin"}
    tags = {}
    patches = []
    for line in text.splitlines():
        m = re.match(r"^\s*%(?:global|define)\s+([A-Za-z_]\w*)\s+(.*?)\s*$", line)
        if m and m.group(1) not in macros:
            macros[m.group(1)] = m.group(2)
            continue
        m = re.match(r"^(Name|Version|Release|Epoch)\s*:\s*(.*?)\s*$", line, re.I)
        if m and m.group(1).lower() not in tags:
            tags[m.group(1).lower()] = m.group(2)
            if m.group(1).lower() in ("name", "version", "release"):
                macros.setdefault(m.group(1).lower(), m.group(2))
            continue
        m = re.match(r"^Patch(\d*)\s*:\s*(\S+)", line, re.I)
        if m:
            patches.append((m.group(1), m.group(2)))
    info = {k: expand(v, macros) for k, v in tags.items()}
    patches = [(num, expand(f, macros)) for num, f in patches]
    m = re.search(r"^%changelog[ \t]*$", text, re.M)
    log_text = text[m.end():].lstrip("\n") if m else ""
    return info, patches, log_text


CHLOG_DATE = re.compile(r"^\*\s+\w{3}\s+(\w{3})\s+(\d{1,2})\s+(?:\d\d:\d\d:\d\d\s+(?:\w+\s+)?)?(\d{4})")


def changelog_head(text):
    """The newest entries of a %changelog: CHANGELOG_YEARS years, at least CHANGELOG_MIN."""
    cutoff = datetime.date.today().replace(year=datetime.date.today().year - CHANGELOG_YEARS)
    out_lines, n = [], 0
    for line in text.splitlines():
        if line.startswith("*"):
            m = CHLOG_DATE.match(line)
            day = None
            if m:
                try:
                    day = datetime.datetime.strptime("%s %s %s" % m.groups(), "%b %d %Y").date()
                except ValueError:
                    day = None
            if n >= CHANGELOG_MIN and day is not None and day < cutoff:
                break
            n += 1
        out_lines.append(line)
        if len(out_lines) >= CHANGELOG_MAX_LINES:
            out_lines.append("... (cut at %d lines)" % CHANGELOG_MAX_LINES)
            break
    return "\n".join(out_lines).rstrip() + "\n"


def autochangelog(repo, commit):
    """The changelog rpmautospec makes of the commit messages, as far as a plain
    reading can: the newest CHANGELOG_YEARS years, at least CHANGELOG_MIN entries."""
    raw = out("log", "--no-merges", "--date=format:%a %b %d %Y",
              "--format=* %ad %an <%ae> %h%n%B%x00", "-n", "2000", commit, cwd=repo)
    entries = [e.strip("\n") for e in raw.split("\x00") if e.strip()]
    text = []
    for e in entries:
        head, _, body = e.partition("\n")
        text.append(head)
        text += ["- " + line if line.strip() and not line.startswith(("-", " ")) else line
                 for line in body.strip().splitlines()]
        text.append("")
    return changelog_head("\n".join(text))


# ------------------------------------------------------------------ branches
def branch_order(b):
    m = re.match(r"^f(\d+)$", b)
    if b in ("rawhide", "main", "master"):
        return (0, 0, b)
    if m:
        return (1, -int(m.group(1)), b)
    m = re.match(r"^epel(\d+)(?:\.(\d+))?(.*)$", b)
    if m:
        return (2, -int(m.group(1)), -(int(m.group(2)) if m.group(2) else 99), m.group(3), b)
    m = re.match(r"^el(\d+)$", b)
    if m:
        return (3, -int(m.group(1)), b)
    m = re.match(r"^[a-z]+?(\d+)(s?)(.*)$", b)
    if m:
        return (4, -int(m.group(1)), m.group(2), m.group(3), b)
    return (5, 0, b)


class Repo:
    def __init__(self, path):
        self.path = path
        self.cat = subprocess.Popen(["git", "cat-file", "--batch"], cwd=path, stdin=subprocess.PIPE,
                                    stdout=subprocess.PIPE)

    def blob(self, sha):
        self.cat.stdin.write(sha.encode() + b"\n")
        self.cat.stdin.flush()
        head = self.cat.stdout.readline().decode().split()
        if len(head) < 3 or head[1] == "missing":
            raise RuntimeError("blob %s missing" % sha)
        size = int(head[2])
        data = self.cat.stdout.read(size)
        self.cat.stdout.read(1)
        return data

    def close(self):
        try:
            self.cat.stdin.close()
            self.cat.wait(timeout=30)
        except Exception:  # noqa: BLE001
            self.cat.kill()

    def tree(self, commit):
        """[(path, sha, size)] of the regular files of a commit."""
        files = []
        for line in out("ls-tree", "-r", "-l", "-z", "--full-tree", commit, cwd=self.path).split("\0"):
            if not line:
                continue
            meta, _, path = line.partition("\t")
            mode, typ, sha, size = meta.split()
            if typ != "blob" or mode == "120000":
                continue
            files.append((path, sha, int(size) if size.isdigit() else 0))
        return files


def wanted(path):
    """The name under files/ of a file of the package, or None: the files at the root,
    and those of SPECS/ and SOURCES/ (the layout of git.centos.org)."""
    parts = path.split("/")
    if len(parts) == 1:
        return None if parts[0] in SKIP else parts[0]
    if len(parts) == 2 and parts[0] in ("SPECS", "SOURCES") and parts[1] not in SKIP:
        return parts[1]
    return None


def fetch_package(source, pkg, outdir, branch_re, work):
    """Clone the dist-git repository of pkg and write its branches; a list of rows for
    the report: (branch, version-release, directory or "same as", note)."""
    url = os.environ.get("DISTRO_URL", SOURCES[source][0]) % pkg
    repo_dir = os.path.join(work, pkg + ".git")
    try:
        git("clone", "-q", "--bare", "--no-tags", url, repo_dir, timeout=1800)
    except RuntimeError as e:
        msg = str(e)
        if re.search(r"not found|could not read Username|Authentication failed|repository .* does not exist|"
                     r"returned error: 40[134]", msg, re.I):
            return None, "no repository %s" % url
        raise
    repo = Repo(repo_dir)
    rows = []
    try:
        branches = [b for b in out("for-each-ref", "--format=%(refname:short)", "refs/heads/",
                                   cwd=repo_dir).split() if b]
        branches.sort(key=branch_order)
        seen = {}
        for b in branches:
            if branch_re and not branch_re.fullmatch(b):
                continue
            head = out("rev-parse", "refs/heads/" + b, cwd=repo_dir).strip()
            commit, retired = head, None
            names = {p for p, _, _ in repo.tree(head)}
            if "dead.package" in names:
                dead = out("log", "-1", "--format=%H %ad", "--date=short", "--diff-filter=A", head, "--",
                           "dead.package", cwd=repo_dir).split()
                reason = git("show", "%s:dead.package" % head, cwd=repo_dir, check=False).stdout.decode(
                    "utf-8", "replace").strip().replace("\n", " ")[:300]
                parent = git("rev-parse", "-q", "--verify", "%s^" % dead[0], cwd=repo_dir,
                             check=False).stdout.decode().strip() if dead else ""
                retired = "%s (%s): %s" % (dead[1] if len(dead) > 1 else "?", dead[0][:12] if dead else "?",
                                           reason or "dead.package")
                if not parent:
                    rows.append((b, "-", "-", "retired, nothing before: " + retired))
                    continue
                commit = parent
            files = [(p, sha, size) for p, sha, size in repo.tree(commit) if wanted(p)]
            specs = [f for f in files if f[0].endswith(".spec")]
            if not specs:
                rows.append((b, "-", "-", "no spec at %s" % commit[:12] + (", retired " + retired if retired else "")))
                continue
            specs.sort(key=lambda f: (os.path.basename(f[0]) != pkg + ".spec", f[0]))
            key = hashlib.sha1("\n".join("%s %s" % (p, sha) for p, sha, _ in sorted(files)).encode()).hexdigest()
            spec_text = repo.blob(specs[0][1]).decode("utf-8", "replace")
            info, patches, log_text = read_spec(spec_text)
            evr = "%s-%s" % (info.get("version", "?"), info.get("release", "?"))
            if key in seen:
                first = seen[key]
                rows.append((b, evr, "same as " + first, "retired " + retired if retired else ""))
                with open(os.path.join(outdir, pkg, safe_name(first), "source.txt"), "a") as f:
                    f.write("Same files on: %s (%s)%s\n" % (b, commit[:12], ", retired " + retired if retired
                                                            else ""))
                continue
            seen[key] = b
            dest = os.path.join(outdir, pkg, safe_name(b))
            os.makedirs(os.path.join(dest, "files"), exist_ok=True)
            listing, left_out = [], []
            for p, sha, size in sorted(files):
                name = wanted(p)
                if p == specs[0][0]:
                    target = os.path.join(dest, os.path.basename(p))
                else:
                    target = os.path.join(dest, "files", name)
                    if os.path.exists(target):
                        target = os.path.join(dest, "files", p.replace("/", "_"))
                if size > FILE_LIMIT:
                    left_out.append("%s (%d bytes, git blob %s: left out, bigger than %d)" % (p, size, sha,
                                                                                             FILE_LIMIT))
                    continue
                with open(target, "wb") as f:
                    f.write(repo.blob(sha))
                listing.append("%s %d %s" % (p, size, sha))
            if log_text.strip().startswith("%autochangelog") or not log_text.strip():
                chlog = autochangelog(repo_dir, commit)
                kind = "the commit messages (%autochangelog)" if log_text.strip() else "the commit messages (no %changelog)"
            else:
                chlog = changelog_head(log_text)
                kind = "the %changelog of the spec"
            with open(os.path.join(dest, "changelog"), "w") as f:
                f.write(chlog)
            with open(os.path.join(dest, "commits.txt"), "w") as f:
                f.write(out("log", "--date=short", "--format=%h %ad %an%x09%s", "-n", str(COMMITS), commit,
                            cwd=repo_dir))
            cdate, csubj = out("log", "-1", "--date=short", "--format=%ad%x09%s", commit,
                               cwd=repo_dir).rstrip("\n").partition("\t")[::2]
            present = {os.path.basename(p) for p, _, _ in files}
            info_lines = [
                "Source: %s (%s)" % (source, url),
                "Package: %s" % pkg,
                "Branch: %s" % b,
                "Commit: %s %s %s" % (commit, cdate, csubj),
                "Commit URL: %s" % (SOURCES[source][1] % (pkg, commit)),
            ]
            if retired:
                info_lines.append("Retired: %s (the files are those of the commit before)" % retired)
            info_lines += ["%s: %s" % (k.capitalize(), info[k]) for k in ("name", "epoch", "version", "release")
                           if k in info]
            info_lines.append("Spec: %s" % specs[0][0])
            info_lines.append("Changelog: %s" % kind)
            info_lines.append("Patch lines of the spec:")
            info_lines += ["  Patch%s: %s%s" % (num, f, "" if os.path.basename(f) in present else
                                                  " (not in the repository: lookaside or URL)")
                           for num, f in patches]
            info_lines.append("Files (path, size, git blob):")
            info_lines += ["  " + x for x in listing + left_out]
            with open(os.path.join(dest, "source.txt"), "w") as f:
                f.write("\n".join(info_lines) + "\n")
            rows.append((b, evr, safe_name(b), "retired " + retired if retired else ""))
    finally:
        repo.close()
        shutil.rmtree(repo_dir, ignore_errors=True)
    return rows, None


def safe_name(branch):
    return re.sub(r"[^A-Za-z0-9.+_-]", "_", branch)


def index_md(pkgdir, source, pkg, day, rows):
    lines = ["# %s: %s, %s" % (pkg, SOURCES[source][2], day), "",
             "Written by tools/distro-fetch.py of azsupport/php-src (workflow distro-fetch.yml), from %s." % (
                 os.environ.get("DISTRO_URL", SOURCES[source][0]) % pkg), "",
             "| branch | version-release | directory | note |", "|---|---|---|---|"]
    for b, evr, d, note in rows:
        cell = "[%s](%s/)" % (d, d) if d not in ("-",) and not d.startswith("same as") else d
        lines.append("| %s | %s | %s | %s |" % (b, evr.replace("|", "\\|"), cell, note.replace("|", "\\|")))
    with open(os.path.join(pkgdir, "index.md"), "w") as f:
        f.write("\n".join(lines) + "\n")


def push(outdir, source, day, packages, run):
    """Commit <outdir> into the branch runs of azsupport/azsupport, RUNS_DIR/<source>/<day>/."""
    remote = os.environ.get("RUNS_REMOTE") or (RUNS_URL % os.environ["RUNS_TOKEN"]
                                               if os.environ.get("RUNS_TOKEN") else None)
    if not remote:
        warn("RUNS_TOKEN is not set: nothing pushed")
        return False
    target = "%s/%s/%s" % (RUNS_DIR, source, day)
    for attempt in range(1, 9):
        work = tempfile.mkdtemp()
        try:
            repo = os.path.join(work, "r")
            git("clone", "-q", "--depth", "1", "--filter=blob:none", "--sparse", "--branch", "runs",
                "--single-branch", remote, repo)
            git("sparse-checkout", "set", target, cwd=repo)
            for pkg in sorted(os.listdir(outdir)):
                dst = os.path.join(repo, target, pkg)
                if os.path.exists(dst):
                    shutil.rmtree(dst)
                shutil.copytree(os.path.join(outdir, pkg), dst)
            git("add", "-A", target, cwd=repo)
            if not git("status", "--porcelain", cwd=repo).stdout.strip():
                log("runs: nothing new to commit")
                return True
            git("-c", "user.name=github-actions[bot]",
                "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
                "commit", "-q", "-m", "distro-fetch %s: %s (run %s)" % (source, " ".join(packages)[:200], run),
                cwd=repo)
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
    ap.add_argument("--source", required=True, choices=sorted(SOURCES))
    ap.add_argument("--out", required=True)
    ap.add_argument("--report")
    ap.add_argument("--branches", default="")
    ap.add_argument("--push", action="store_true")
    ap.add_argument("packages", nargs="*")
    a = ap.parse_args()

    asked = []
    for item in " ".join(a.packages).replace(",", " ").split():
        if not NAME.match(item):
            warn("not a package name: %r, left out" % item)
        elif item not in asked:
            asked.append(item)
    if not asked:
        log("no packages")
        return 2
    try:
        branch_re = re.compile(a.branches.strip()) if a.branches.strip() else None
    except re.error as e:
        log("--branches: %s" % e)
        return 2

    os.makedirs(a.out, exist_ok=True)
    work = tempfile.mkdtemp(prefix="distro-fetch-")
    results, missing, errors = {}, [], []
    for pkg in asked:
        log("%s: %s" % (source_name(a.source), pkg))
        try:
            rows, why = fetch_package(a.source, pkg, a.out, branch_re, work)
        except Exception as e:  # noqa: BLE001
            errors.append("%s: %s" % (pkg, e))
            shutil.rmtree(os.path.join(a.out, pkg), ignore_errors=True)
            continue
        if rows is None:
            missing.append("%s (%s)" % (pkg, why))
            continue
        if not any(not d.startswith("same as") and d != "-" for _, _, d, _ in rows):
            missing.append("%s (no branch with a spec%s)" % (pkg, " matching --branches" if branch_re else ""))
        results[pkg] = rows
    shutil.rmtree(work, ignore_errors=True)
    for e in errors:
        warn(e)

    day = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    for pkg, rows in results.items():
        if os.path.isdir(os.path.join(a.out, pkg)):
            index_md(os.path.join(a.out, pkg), a.source, pkg, day, rows)
    pushed = None
    if a.push and any(os.path.isdir(os.path.join(a.out, p)) for p in results):
        pushed = push(a.out, a.source, day, asked, os.environ.get("GITHUB_RUN_ID", "local"))

    rep = ["### Distro fetch: %s" % source_name(a.source), "",
           "Packages: `%s`; branches: %s." % (" ".join(asked), "`%s`" % a.branches if a.branches else "all"), ""]
    if pushed:
        rep += ["Pushed to the branch runs of azsupport/azsupport: `%s/%s/%s/<package>/<branch>/`." % (
            RUNS_DIR, a.source, day), ""]
    elif a.push:
        rep += ["**Not pushed** to azsupport/azsupport (see the warnings).", ""]
    rep += ["| package | branch | version-release | directory | note |", "|---|---|---|---|---|"]
    for pkg, rows in results.items():
        for b, evr, d, note in rows:
            rep.append("| %s | %s | %s | %s | %s |" % (pkg, b, evr.replace("|", "\\|"), d,
                                                        note.replace("|", "\\|")))
    if missing:
        rep += ["", "Not there: %s" % ", ".join(missing)]
    if warnings:
        rep += ["", "Warnings:", ""] + ["- %s" % w for w in warnings]
    text = "\n".join(rep) + "\n"
    if a.report:
        with open(a.report, "w") as f:
            f.write(text)
    print(text)
    if not results:
        return 1
    if errors:
        return 1
    return 0 if (pushed or not a.push) else 1


def source_name(source):
    return SOURCES[source][2]


if __name__ == "__main__":
    sys.exit(main())
