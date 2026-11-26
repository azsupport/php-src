#!/usr/bin/env python3
"""tools/facts-fetch.py <eol|freebsd-pkg|cve-dates> ... - the fetches behind the facts tables of
our ports (the database db/ of the private azsupport/azsupport: db/upstream.tsv,
db/official-freebsd.tsv, db/cve-timing.tsv), from sites the sandbox of Claude Code cannot reach.
The files go into the branch runs of azsupport/azsupport (secret RUNS_TOKEN, as
tools/ubuntu-cve-fetch.py pushes them); nothing is decided here: the importers of db/ read them.

  eol [--git FILE] [--products FILE]
      endoflife.date: every product with its release cycles (support, security support, LTS,
      latest release and its date): the API v1 (/api/v1/products/full; product by product when
      that fails; the API v0 /api/all.json and /api/<product>.json last). With --git, the
      releases of upstream projects: FILE has one source a line, a git repository (all its tags,
      their tip commits only, with the date of each tag: the tagger date of an annotated tag,
      the commit date of a lightweight one) or a download listing ending in "/" (the names in
      it with their dates). --products keeps the products to those of FILE.
      Out: distro/eol/<YYYY-MM-DD>/<run>.json ({"eol": ..., "upstream": ...}) and <run>.md.

  freebsd-pkg [--abis "FreeBSD:15:amd64"] [--branches "latest quarterly"] [--origins FILE]
      The official package catalogs of FreeBSD (https://pkg.freebsd.org/<abi>/<branch>/
      packagesite.pkg): a line per package (name, origin, version, flatsize, the number of its
      run dependencies, their names, flavor); --origins keeps the packages of those origins.
      Out: distro/freebsd-pkg/<YYYY-MM-DD>/<run>/<abi>-<branch>.tsv and state.txt (the sha256
      and the date of each catalog: the reference point).

  cve-dates [--cves FILE] [--ports FILE]
      When a fix reached Debian, Ubuntu and FreeBSD: the advisories of Debian (DSA and DLA lists
      of the security tracker, all of them), the tracker's entries of the CVEs of FILE (fixed
      version per release) and the unstable changelogs of their source packages (the date of
      each version and the CVEs it names); the notices of Ubuntu (USN, osv/usn of
      canonical/ubuntu-security-notices: date, CVEs, source packages and fixed versions; only
      those naming a CVE of --cves when given); with --ports (lines "<origin> <YYYY-MM-DD>
      [<YYYY-MM-DD>]"), the commits of freebsd/freebsd-ports that changed <origin>/Makefile since
      the first day (up to the second), with their version lines (the GitHub API, GITHUB_TOKEN).
      Out: distro/cve-dates/<YYYY-MM-DD>/<run>/ (debian-dsa.tsv, debian-dla.tsv,
      debian-tracker.tsv, debian-changelog.tsv, ubuntu-usn.tsv, freebsd-commits.tsv, state.txt).

Common: --out DIR (the files before the push), --report FILE (the summary of the run, for
tools/runs-report.sh), --push (to the branch runs). Standard library, git, curl and tar only.
"""
import argparse
import datetime
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

RUNS_URL = "https://x-access-token:%s@github.com/azsupport/azsupport.git"
UA = "facts-fetch (azsupport/php-src)"


def log(msg):
    print("facts-fetch: " + msg, flush=True)


def hide(s):
    return re.sub(r"x-access-token:[^@]*@", "x-access-token:***@", s)


def push(files, what, run):
    """Commit files ({path in runs: local path}) to the branch runs of azsupport/azsupport."""
    token = os.environ.get("RUNS_TOKEN")
    if not token:
        log("RUNS_TOKEN is not set: nothing pushed")
        return False
    remote = RUNS_URL % token

    def git(*args, cwd=None, check=True):
        r = subprocess.run(("git",) + args, cwd=cwd, capture_output=True, text=True)
        if check and r.returncode:
            raise RuntimeError("git %s: %s" % (args[0], hide((r.stderr or r.stdout).strip())[-500:]))
        return r

    dirs = sorted({os.path.dirname(p) for p in files})
    for attempt in range(1, 7):
        work = tempfile.mkdtemp()
        try:
            repo = os.path.join(work, "r")
            git("clone", "-q", "--depth", "1", "--filter=blob:none", "--sparse", "--branch", "runs",
                "--single-branch", remote, repo)
            git("sparse-checkout", "set", *dirs, cwd=repo)
            for dst, src in files.items():
                os.makedirs(os.path.join(repo, os.path.dirname(dst)), exist_ok=True)
                shutil.copyfile(src, os.path.join(repo, dst))
            git("add", "-A", *dirs, cwd=repo)
            if not git("status", "--porcelain", cwd=repo).stdout.strip():
                log("runs: nothing new to commit")
                return True
            git("-c", "user.name=github-actions[bot]",
                "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
                "commit", "-q", "-m", "facts-fetch: %s (run %s)" % (what, run), cwd=repo)
            r = git("push", "-q", "origin", "HEAD:runs", cwd=repo, check=False)
            if r.returncode == 0:
                log("runs: pushed %s" % what)
                return True
            log("runs: push refused (attempt %d), again on the new tip" % attempt)
        except RuntimeError as e:
            log("runs: %s (attempt %d)" % (e, attempt))
        finally:
            shutil.rmtree(work, ignore_errors=True)
        time.sleep(5 * attempt)
    log("push to azsupport/azsupport (runs) failed")
    return False


def http(url, timeout=60, tries=3, headers=None):
    """(bytes, response headers) of url; raises the last error."""
    err = None
    for i in range(tries):
        try:
            h = {"User-Agent": UA}
            h.update(headers or {})
            with urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=timeout) as r:
                return r.read(), dict(r.headers)
        except urllib.error.HTTPError as e:
            err = e
            if e.code in (403, 404, 410):
                break
        except Exception as e:  # noqa: BLE001
            err = e
        time.sleep(3 * (i + 1))
    raise err


def lines_of(path):
    if not path or not os.path.exists(path):
        return []
    return [x.strip() for x in open(path, encoding="utf-8").read().replace(",", " ").split("\n") if x.strip()]


def words_of(path):
    return " ".join(lines_of(path)).split()


def sha256(b):
    return hashlib.sha256(b).hexdigest()


# --- eol -------------------------------------------------------------------------------------

EOL_V1 = "https://endoflife.date/api/v1"
EOL_V0 = "https://endoflife.date/api"


def eol_products(wanted):
    """{"api", "urls", "products": {name: data}, "errors"}: v1 full, v1 one by one, v0."""
    out = {"api": "", "urls": [], "products": {}, "errors": []}
    if not wanted:
        try:
            b, _ = http(EOL_V1 + "/products/full", timeout=180)
            d = json.loads(b)
            res = d.get("result") if isinstance(d, dict) else None
            if isinstance(res, list) and res:
                out.update(api="v1", urls=[EOL_V1 + "/products/full"],
                           products={p.get("name"): p for p in res if isinstance(p, dict) and p.get("name")})
                out["schema_version"] = d.get("schema_version", "")
                return out
            out["errors"].append("v1 products/full: no result list")
        except Exception as e:  # noqa: BLE001
            out["errors"].append("v1 products/full: %s" % e)
    names = list(wanted)
    if not names:
        try:
            b, _ = http(EOL_V1 + "/products")
            names = [p.get("name") for p in json.loads(b).get("result", []) if p.get("name")]
            out["urls"].append(EOL_V1 + "/products")
        except Exception as e:  # noqa: BLE001
            out["errors"].append("v1 products: %s" % e)
    api = "v1"
    if not names:
        try:
            b, _ = http(EOL_V0 + "/all.json")
            names = json.loads(b)
            out["urls"].append(EOL_V0 + "/all.json")
            api = "v0"
        except Exception as e:  # noqa: BLE001
            out["errors"].append("v0 all.json: %s" % e)
    for n in names:
        for kind, url in (("v1", EOL_V1 + "/products/" + n), ("v0", EOL_V0 + "/" + n + ".json")):
            if api == "v0" and kind == "v1":
                continue
            try:
                b, _ = http(url)
                d = json.loads(b)
                out["products"][n] = d.get("result", d) if kind == "v1" and isinstance(d, dict) else {"v0": d}
                break
            except Exception as e:  # noqa: BLE001
                out["errors"].append("%s %s: %s" % (kind, n, e))
        time.sleep(0.2)
    out["api"] = api
    return out


LISTING_DATE = re.compile(r"(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2})|(\d{2})-([A-Z][a-z]{2})-(\d{4}) (\d{2}:\d{2})")


def listing(url):
    """[[name, "", date, ""]] of the links of a download listing, with the date on their line."""
    b, _ = http(url)
    text = b.decode("utf-8", "replace")
    out, seen = [], set()
    for line in re.split(r"\n|<tr", text):
        for m in re.finditer(r'href="([^"?/#][^"?#]*)"', line):
            name = m.group(1)
            if name in seen or name.startswith(("http:", "https:", "mailto:", "..")):
                continue
            seen.add(name)
            day = ""
            dm = LISTING_DATE.search(line[m.end():])
            if dm and dm.group(1):
                day = "%sT%s" % (dm.group(1), dm.group(2))
            elif dm:
                try:
                    day = datetime.datetime.strptime("%s-%s-%s %s" % dm.group(3, 4, 5, 6),
                                                     "%d-%b-%Y %H:%M").strftime("%Y-%m-%dT%H:%M")
                except ValueError:
                    day = ""
            out.append([name, "", day, ""])
    return out


def git_tags(url, work):
    """[[tag, commit, tag date, commit date]] of the tags of a git repository: their tip commits
    only (depth 1, no trees)."""
    d = os.path.join(work, re.sub(r"[^A-Za-z0-9]+", "_", url)[-80:] + ".git")
    subprocess.run(["git", "init", "-q", "--bare", d], check=True)
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    r = subprocess.run(["git", "-C", d, "fetch", "-q", "--depth", "1", "--filter=tree:0", "--no-tags", url,
                        "+refs/tags/*:refs/tags/*"], capture_output=True, text=True, env=env, timeout=900)
    if r.returncode:
        raise RuntimeError(hide(r.stderr.strip())[-300:] or "git fetch failed")
    fmt = "%(refname:strip=2)%09%(*objectname)%09%(objectname)%09%(creatordate:iso-strict)%09%(*committerdate:iso-strict)"
    out = []
    for line in subprocess.run(["git", "-C", d, "for-each-ref", "refs/tags", "--format=" + fmt],
                               capture_output=True, text=True).stdout.splitlines():
        f = line.split("\t")
        if len(f) < 5:
            continue
        tag, peeled, obj, created, cdate = f
        out.append([tag, peeled or obj, created, cdate or created])
    shutil.rmtree(d, ignore_errors=True)
    return out


def do_eol(a, out, run, day):
    rep = ["### Facts fetch: eol", ""]
    eol = eol_products(words_of(a.products))
    cycles = sum(len(p.get("releases", []) if isinstance(p, dict) else []) for p in eol["products"].values())
    rep.append("- endoflife.date: API %s, %d products, %d release cycles%s" % (
        eol["api"] or "-", len(eol["products"]), cycles, (", errors: %d" % len(eol["errors"])) if eol["errors"] else ""))
    for e in eol["errors"][:10]:
        rep.append("  - %s" % e)
    up, ok, bad = {}, 0, 0
    work = tempfile.mkdtemp()
    for src in lines_of(a.git):
        src = src.split()[0]
        try:
            refs = listing(src) if src.endswith("/") else git_tags(src, work)
            up[src] = {"kind": "listing" if src.endswith("/") else "git", "refs": refs}
            ok += 1
        except Exception as e:  # noqa: BLE001
            up[src] = {"kind": "listing" if src.endswith("/") else "git", "error": str(e)[:300], "refs": []}
            bad += 1
    if up:
        rep.append("- upstream sources: %d read, %d failed" % (ok, bad))
        rep += ["  - %s: %s" % (s, v["error"]) for s, v in sorted(up.items()) if v.get("error")]
    data = {"fetched": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "run": run,
            "eol": eol, "upstream": up}
    os.makedirs(out, exist_ok=True)
    j = os.path.join(out, "%s.json" % run)
    with open(j, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=1, sort_keys=True)
    eol_sha = sha256(json.dumps(eol["products"], sort_keys=True).encode())
    md = rep + ["", "- eol sha256 (products, sorted JSON): %s" % eol_sha,
                "- file: distro/eol/%s/%s.json" % (day, run)]
    with open(os.path.join(out, "%s.md" % run), "w", encoding="utf-8") as fh:
        fh.write("\n".join(md) + "\n")
    files = {"distro/eol/%s/%s.json" % (day, run): j, "distro/eol/%s/%s.md" % (day, run): os.path.join(out, "%s.md" % run)}
    return md, files, "distro/eol/%s/%s" % (day, run), bool(eol["products"])


# --- freebsd-pkg -----------------------------------------------------------------------------

def catalog(abi, branch, work):
    base = "https://pkg.freebsd.org/%s/%s/" % (abi, branch)
    last = None
    for name in ("packagesite.pkg", "packagesite.tzst", "packagesite.txz"):
        f = os.path.join(work, "%s-%s-%s" % (abi.replace(":", "_"), branch, name))
        try:
            b, h = http(base + name, timeout=300)
        except Exception as e:  # noqa: BLE001
            last = "%s: %s" % (name, e)
            continue
        open(f, "wb").write(b)
        r = subprocess.run(["tar", "-xOf", f, "packagesite.yaml"], capture_output=True)
        if r.returncode or not r.stdout:
            last = "%s: tar: %s" % (name, r.stderr.decode("utf-8", "replace").strip()[-200:])
            continue
        return {"url": base + name, "sha256": sha256(b), "size": len(b), "last_modified": h.get("Last-Modified", ""),
                "yaml": r.stdout}
    raise RuntimeError(last or "no catalog")


def do_freebsd_pkg(a, out, run, day):
    rep = ["### Facts fetch: freebsd-pkg", ""]
    origins = set(words_of(a.origins))
    work = tempfile.mkdtemp()
    os.makedirs(out, exist_ok=True)
    state = ["# the official package catalogs of FreeBSD, fetched %s (run %s)" % (
        datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"), run),
        "# origins kept: %s" % ("%d asked" % len(origins) if origins else "all")]
    done = 0
    for abi in a.abis.split():
        for branch in a.branches.split():
            try:
                c = catalog(abi, branch, work)
            except Exception as e:  # noqa: BLE001
                rep.append("- %s %s: %s" % (abi, branch, e))
                state.append("%s\t%s\terror\t%s" % (abi, branch, str(e)[:200]))
                continue
            rows, total = [], 0
            for line in c["yaml"].decode("utf-8", "replace").splitlines():
                try:
                    p = json.loads(line)
                except ValueError:
                    continue
                total += 1
                if origins and p.get("origin") not in origins:
                    continue
                deps = sorted((p.get("deps") or {}).keys())
                flavor = (p.get("annotations") or {}).get("flavor", "")
                rows.append("\t".join(str(x) for x in (p.get("name", ""), p.get("origin", ""), p.get("version", ""),
                                                        p.get("flatsize", ""), len(deps), ",".join(deps), flavor)))
            name = "%s-%s.tsv" % (abi.replace(":", "_"), branch)
            with open(os.path.join(out, name), "w", encoding="utf-8") as fh:
                fh.write("name\torigin\tversion\tflatsize\tdeps_count\tdeps\tflavor\n")
                fh.write("\n".join(sorted(rows)) + ("\n" if rows else ""))
            state.append("%s\t%s\t%s\tsha256 %s\tsize %d\tlast-modified %s\tpackages %d\trows %d" % (
                abi, branch, c["url"], c["sha256"], c["size"], c["last_modified"], total, len(rows)))
            rep.append("- %s %s: %d packages, %d kept (sha256 %s, %s)" % (abi, branch, total, len(rows),
                                                                         c["sha256"][:16], c["last_modified"]))
            done += 1
    with open(os.path.join(out, "state.txt"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(state) + "\n")
    target = "distro/freebsd-pkg/%s/%s" % (day, run)
    files = {"%s/%s" % (target, f): os.path.join(out, f) for f in os.listdir(out)}
    return rep, files, target, done > 0


# --- cve-dates -------------------------------------------------------------------------------

SALSA = "https://salsa.debian.org/security-tracker-team/security-tracker/-/raw/master/data/%s/list"
SALSA_HEAD = ("https://salsa.debian.org/api/v4/projects/security-tracker-team%2Fsecurity-tracker/repository/"
              "commits?per_page=1")
TRACKER = "https://security-tracker.debian.org/tracker/data/json"
CHANGELOG = "https://metadata.ftp-master.debian.org/changelogs//main/%s/%s/unstable_changelog"
ADVISORY_HEAD = re.compile(r"^\[(\d{1,2}) (\w{3}) (\d{4})\] ((?:DSA|DLA|DTSA)-\d+(?:-\d+)?) (\S+)(?: - (.*))?$")
ADVISORY_FIX = re.compile(r"^\[(\S+)\] - (\S+) (\S+)")
CHANGELOG_HEAD = re.compile(r"^(\S+) \(([^)]+)\) ([^;]+);")
CVE = re.compile(r"CVE-\d{4}-\d{4,}")


def debian_list(kind):
    b, _ = http(SALSA % kind, timeout=120)
    rows, cur = [], None
    for line in b.decode("utf-8", "replace").splitlines():
        m = ADVISORY_HEAD.match(line)
        if m:
            try:
                d = datetime.datetime.strptime(" ".join(m.group(1, 2, 3)), "%d %b %Y").date().isoformat()
            except ValueError:
                cur = None
                continue
            cur = {"id": m.group(4), "date": d, "pkgs": [m.group(5)], "cves": [], "fixed": []}
            rows.append(cur)
            continue
        if cur is None:
            continue
        s = line.strip()
        if s.startswith("{"):
            cur["cves"] += s.strip("{}").split()
        f = ADVISORY_FIX.match(s)
        if f:
            if f.group(2) not in cur["pkgs"]:
                cur["pkgs"].append(f.group(2))
            cur["fixed"].append("%s=%s %s" % (f.group(1), f.group(2), f.group(3)))
    return rows, sha256(b)


def changelog_rows(src, text):
    rows, cur = [], None
    for line in text.splitlines():
        m = CHANGELOG_HEAD.match(line)
        if m and m.group(1) == src:
            cur = {"version": m.group(2), "dist": m.group(3).strip(), "cves": [], "date": ""}
            rows.append(cur)
            continue
        if cur is None:
            continue
        if line.startswith(" -- "):
            dm = re.search(r">\s+(.+)$", line)
            if dm:
                try:
                    cur["date"] = datetime.datetime.strptime(dm.group(1).strip(), "%a, %d %b %Y %H:%M:%S %z").isoformat()
                except ValueError:
                    cur["date"] = dm.group(1).strip()
            continue
        for c in CVE.findall(line):
            if c not in cur["cves"]:
                cur["cves"].append(c)
    return rows


def gh_json(path):
    tok = os.environ.get("GITHUB_TOKEN", "")
    h = {"Accept": "application/vnd.github+json"}
    if tok:
        h["Authorization"] = "Bearer " + tok
    b, _ = http("https://api.github.com/" + path, headers=h)
    return json.loads(b)


VERSION_LINE = re.compile(r"^(DISTVERSIONPREFIX|DISTVERSION|DISTVERSIONSUFFIX|PORTVERSION|PORTREVISION|PORTEPOCH)"
                          r"\s*[?:+]?=\s*(.*?)\s*$", re.M)


def do_cve_dates(a, out, run, day):
    rep = ["### Facts fetch: cve-dates", ""]
    os.makedirs(out, exist_ok=True)
    cves = set(words_of(a.cves))
    state = ["# when fixes reached Debian, Ubuntu and FreeBSD, fetched %s (run %s); CVEs asked: %s" % (
        datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"), run, len(cves) or "all")]
    ok = True
    # Debian: the DSA and DLA lists, all of them
    for kind in ("DSA", "DLA"):
        try:
            rows, h = debian_list(kind)
            with open(os.path.join(out, "debian-%s.tsv" % kind.lower()), "w", encoding="utf-8") as fh:
                fh.write("id\tdate\tpackages\tcves\tfixed\n")
                for r in rows:
                    fh.write("\t".join([r["id"], r["date"], " ".join(r["pkgs"]), " ".join(r["cves"]),
                                        "; ".join(r["fixed"])]) + "\n")
            state.append("debian %s list: %s sha256 %s, %d advisories" % (kind, SALSA % kind, h, len(rows)))
            rep.append("- Debian %s: %d advisories" % (kind, len(rows)))
        except Exception as e:  # noqa: BLE001
            ok = False
            rep.append("- Debian %s: %s" % (kind, e))
            state.append("debian %s list: error %s" % (kind, e))
    try:
        c = json.loads(http(SALSA_HEAD)[0])[0]
        state.append("debian security-tracker head: %s %s" % (c.get("id", ""), c.get("committed_date", "")))
    except Exception as e:  # noqa: BLE001
        state.append("debian security-tracker head: unknown (%s)" % e)
    # Debian: the tracker's entries of the CVEs asked, and the changelogs of their sources
    srcs = set()
    if cves:
        try:
            b, _ = http(TRACKER, timeout=600)
            data = json.loads(b)
            n = 0
            with open(os.path.join(out, "debian-tracker.tsv"), "w", encoding="utf-8") as fh:
                fh.write("cve\tsource\trelease\tstatus\tfixed_version\turgency\n")
                for src, entries in sorted(data.items()):
                    for cve, e in sorted(entries.items()):
                        if cve not in cves:
                            continue
                        for rel, r in sorted((e.get("releases") or {}).items()):
                            fh.write("\t".join([cve, src, rel, r.get("status", ""), r.get("fixed_version", ""),
                                                r.get("urgency", "")]) + "\n")
                            n += 1
                        srcs.add(src)
            state.append("debian tracker json: %s sha256 %s, %d rows" % (TRACKER, sha256(b), n))
            rep.append("- Debian tracker: %d rows of %d source packages" % (n, len(srcs)))
        except Exception as e:  # noqa: BLE001
            ok = False
            rep.append("- Debian tracker: %s" % e)
            state.append("debian tracker json: error %s" % e)
    nlog = 0
    with open(os.path.join(out, "debian-changelog.tsv"), "w", encoding="utf-8") as fh:
        fh.write("source\tversion\tdistribution\tdate\tcves\n")
        for src in sorted(srcs):
            prefix = src[:4] if src.startswith("lib") else src[:1]
            try:
                text = http(CHANGELOG % (prefix, src), tries=2)[0].decode("utf-8", "replace")
            except Exception as e:  # noqa: BLE001
                state.append("debian changelog %s: %s" % (src, e))
                continue
            for r in changelog_rows(src, text):
                fh.write("\t".join([src, r["version"], r["dist"], r["date"], " ".join(r["cves"])]) + "\n")
            nlog += 1
            time.sleep(0.3)
    rep.append("- Debian changelogs (unstable): %d of %d sources" % (nlog, len(srcs)))
    # Ubuntu: the notices
    usn = os.path.join(tempfile.mkdtemp(), "usn")
    try:
        subprocess.run(["git", "clone", "-q", "--depth", "1", "--filter=blob:none", "--sparse",
                        "https://github.com/canonical/ubuntu-security-notices.git", usn], check=True, timeout=1200)
        subprocess.run(["git", "-C", usn, "sparse-checkout", "set", "--no-cone", "/osv/usn/"], check=True, timeout=3600)
        head = subprocess.run(["git", "-C", usn, "log", "-1", "--format=%H %cI"], capture_output=True,
                              text=True).stdout.strip()
        n = files = 0
        with open(os.path.join(out, "ubuntu-usn.tsv"), "w", encoding="utf-8") as fh:
            fh.write("id\tpublished\tsource\tfixed\tcves\n")
            for f in sorted(glob.glob(os.path.join(usn, "osv", "usn", "*.json"))):
                files += 1
                try:
                    d = json.load(open(f, encoding="utf-8"))
                except ValueError:
                    continue
                ids = [re.sub(r"^UBUNTU-", "", x) for x in (d.get("upstream") or []) + (d.get("related") or []) +
                       (d.get("aliases") or [])]
                ids = sorted({x for x in ids if x.startswith("CVE-")})
                if cves and not cves.intersection(ids):
                    continue
                per = {}
                for af in d.get("affected") or []:
                    p = af.get("package") or {}
                    name = p.get("name", "")
                    if not cves and name.startswith("linux"):
                        continue
                    fixed = [ev["fixed"] for r in af.get("ranges") or [] for ev in r.get("events") or [] if "fixed" in ev]
                    eco = p.get("ecosystem", "").replace("Ubuntu:", "")
                    per.setdefault(name, []).append("%s=%s" % (eco, fixed[-1] if fixed else ""))
                for name, fx in sorted(per.items()):
                    fh.write("\t".join([d.get("id", ""), d.get("published", ""), name, "; ".join(fx),
                                        " ".join(ids)]) + "\n")
                    n += 1
        state.append("ubuntu usn: canonical/ubuntu-security-notices %s, %d files, %d rows" % (head, files, n))
        rep.append("- Ubuntu USN: %d files, %d rows (canonical/ubuntu-security-notices %s)" % (files, n, head[:12]))
    except Exception as e:  # noqa: BLE001
        ok = False
        rep.append("- Ubuntu USN: %s" % e)
        state.append("ubuntu usn: error %s" % e)
    # FreeBSD: the commits of the Makefiles of the ports asked
    ports = [x.split() for x in lines_of(a.ports)]
    if ports:
        n = 0
        with open(os.path.join(out, "freebsd-commits.tsv"), "w", encoding="utf-8") as fh:
            fh.write("origin\tcommit\tdate\tsubject\tversion_lines\n")
            for w in ports:
                if len(w) < 2 or not re.match(r"^[a-z0-9-]+/[A-Za-z0-9._+-]+$", w[0]) or not re.match(r"^\d{4}-\d{2}-\d{2}$", w[1]):
                    continue
                origin, since = w[0], w[1]
                until = ("&until=%sT23:59:59Z" % w[2]) if len(w) > 2 and re.match(r"^\d{4}-\d{2}-\d{2}$", w[2]) else ""
                try:
                    page, commits = 1, []
                    while page <= 5:
                        lst = gh_json("repos/freebsd/freebsd-ports/commits?path=%s/Makefile&since=%sT00:00:00Z%s"
                                      "&per_page=100&page=%d" % (origin, since, until, page))
                        commits += lst
                        if len(lst) < 100:
                            break
                        page += 1
                    for c in commits:
                        sha = c["sha"]
                        try:
                            mk = http("https://raw.githubusercontent.com/freebsd/freebsd-ports/%s/%s/Makefile" % (
                                sha, origin), tries=2)[0].decode("utf-8", "replace")
                        except Exception as e:  # noqa: BLE001
                            mk = ""
                            state.append("freebsd %s %s: Makefile: %s" % (origin, sha[:12], e))
                        vl = "; ".join("%s=%s" % (m.group(1), m.group(2)) for m in VERSION_LINE.finditer(mk))
                        fh.write("\t".join([origin, sha, c["commit"]["committer"]["date"],
                                            c["commit"]["message"].split("\n")[0][:200].replace("\t", " "), vl]) + "\n")
                        n += 1
                except Exception as e:  # noqa: BLE001
                    state.append("freebsd %s: %s" % (origin, e))
        state.append("freebsd-ports commits: %d ports asked, %d commits" % (len(ports), n))
        rep.append("- freebsd-ports: %d commits of %d ports" % (n, len(ports)))
    with open(os.path.join(out, "state.txt"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(state) + "\n")
    target = "distro/cve-dates/%s/%s" % (day, run)
    files = {"%s/%s" % (target, f): os.path.join(out, f) for f in os.listdir(out)}
    return rep, files, target, ok


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("kind", choices=["eol", "freebsd-pkg", "cve-dates"])
    ap.add_argument("--git")
    ap.add_argument("--products")
    ap.add_argument("--abis", default="FreeBSD:15:amd64")
    ap.add_argument("--branches", default="latest quarterly")
    ap.add_argument("--origins")
    ap.add_argument("--cves")
    ap.add_argument("--ports")
    ap.add_argument("--out", required=True)
    ap.add_argument("--report")
    ap.add_argument("--push", action="store_true")
    a = ap.parse_args()
    run = os.environ.get("GITHUB_RUN_ID", "local")
    day = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    fn = {"eol": do_eol, "freebsd-pkg": do_freebsd_pkg, "cve-dates": do_cve_dates}[a.kind]
    rep, files, target, ok = fn(a, a.out, run, day)
    pushed = push(files, target, run) if a.push else False
    rep += ["", ("Pushed to the branch runs of azsupport/azsupport: `%s`." % target) if pushed
            else "Not pushed (%s)." % ("--push not given" if not a.push else "the push failed")]
    if a.report:
        with open(a.report, "w", encoding="utf-8") as fh:
            fh.write("\n".join(rep) + "\n")
    print("\n".join(rep))
    return 0 if ok and (pushed or not a.push) else 1


if __name__ == "__main__":
    sys.exit(main())
