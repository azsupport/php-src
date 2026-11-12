#!/usr/bin/env python3
"""es6-fetch.py - what a review of Elasticsearch 6.8 and Kibana 6.8 needs from hosts
that only a runner reaches.

The ports textproc/elasticsearch6 and textproc/kibana6 of azsupport/ports install
the release tarballs of Elastic as they are (Elasticsearch 6.8.23, the generic
tarball; Kibana 6.8.23, the darwin tarball). Their review against the CVEs found
after 6.8.23 and against what other distributions patched needs:

  tarballs   the two tarballs (checked against the SHA-256 of the ports), listed:
             every jar of Elasticsearch with the Maven coordinates of its
             META-INF/maven/*/*/pom.properties, every package.json of Kibana
             (name, version, path)
  esa        the security announcements of Elastic (discuss.elastic.co, category
             Security Announcements): the list and the text of every topic
  nvd        the CVEs of NVD for the CPEs elastic:elasticsearch and elastic:kibana,
             with their configurations (the affected version ranges)
  redhat     the security data of Red Hat for the Elasticsearch 6 and Kibana 6 of
             OpenShift Logging (CVEs, their state per package, the errata), and the
             Maven metadata and POMs of Red Hat's builds of Elasticsearch 6.8.1
  maven      maven-metadata.xml of Maven Central for the libraries the tarball of
             Elasticsearch bundles (the newest release of each line)
  urls       any https URLs given (--urls), saved as they are
  githist    the history of paths of GitHub repositories (--githist): the trees
             of other packagers (nixpkgs, homebrew-core, the FreeBSD ports, ...)
             are too large for the sandbox; a partial clone here, from a day on,
             and git log with the patches of the commits that touch the paths

The files go into the branch runs of azsupport/azsupport, under
distro/es6-kibana6/<YYYY-MM-DD>/<part>/ (UTC), committed and pushed with the token
RUNS_TOKEN as tools/runs-report.sh does; a refused push is made again on the new tip.

Usage: python3 tools/es6-fetch.py --out DIR [--report FILE] [--parts LIST]
                                  [--urls LIST] [--githist LIST] [--push]

--githist: items separated by spaces, <owner>/<repo>@<YYYY-MM-DD>:<path>,<path>...
(a path may use the pathspec magic of git, :(glob)**/kibana*).
"""

import argparse
import hashlib
import html
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

UA = "Mozilla/5.0 (compatible; es6-fetch/1.0)"
RUNS_URL = "https://x-access-token:%s@github.com/azsupport/azsupport.git"
RUNS_DIR = "distro/es6-kibana6"

# the distfiles of the ports (their distinfo in azsupport/ports)
TARBALLS = [
    ("elasticsearch", "https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-6.8.23.tar.gz",
     "424af91f838f9e5f13e0292f97cbd6333535450291a621d761bd479dfc2dff78"),
    ("kibana", "https://artifacts.elastic.co/downloads/kibana/kibana-6.8.23-darwin-x86_64.tar.gz",
     "22533365422586a995eee64c9442d2f8bdfed43887e1c5b5af186f4a789614d5"),
]

ESA_CATEGORY = "https://discuss.elastic.co/c/announcements/security-announcements/31.json?page=%d"
ESA_TOPIC = "https://discuss.elastic.co/t/%s/%d.json"

NVD = "https://services.nvd.nist.gov/rest/json/cves/2.0?virtualMatchString=%s&resultsPerPage=2000&startIndex=%d"
NVD_CPES = ["cpe:2.3:a:elastic:elasticsearch", "cpe:2.3:a:elastic:kibana"]

RH_API = "https://access.redhat.com/hydra/rest/securitydata"
RH_PACKAGES = ["elasticsearch6", "kibana6", "elasticsearch", "kibana",
               "openshift-logging/elasticsearch6-rhel8", "openshift-logging/elasticsearch6-rhel9",
               "openshift-logging/kibana6-rhel8", "openshift-logging/kibana6-rhel9",
               "logging-elasticsearch6-container", "logging-kibana6-container",
               "openshift4/ose-logging-elasticsearch6", "openshift4/ose-logging-kibana6"]
RH_MAVEN = ["https://maven.repository.redhat.com/ga/", "https://maven.repository.redhat.com/earlyaccess/all/"]
RH_ARTIFACTS = ["org/elasticsearch/elasticsearch", "org/elasticsearch/distribution/zip/elasticsearch-oss",
                "org/elasticsearch/plugin/transport-netty4-client", "org/elasticsearch/elasticsearch-x-content",
                "org/elasticsearch/elasticsearch-parent"]

MAVEN_CENTRAL = "https://repo1.maven.org/maven2/"
# the libraries of the tarball of Elasticsearch 6.8.23 (its lib/, modules/, lib/tools/)
MAVEN_ARTIFACTS = [
    "com/fasterxml/jackson/core/jackson-core", "com/fasterxml/jackson/core/jackson-databind",
    "com/fasterxml/jackson/core/jackson-annotations",
    "com/fasterxml/jackson/dataformat/jackson-dataformat-yaml", "com/fasterxml/jackson/dataformat/jackson-dataformat-cbor",
    "com/fasterxml/jackson/dataformat/jackson-dataformat-smile", "org/yaml/snakeyaml",
    "io/netty/netty-codec-http", "io/netty/netty-handler", "io/netty/netty-common",
    "org/apache/logging/log4j/log4j-core", "org/apache/lucene/lucene-core", "joda-time/joda-time",
    "org/apache/httpcomponents/httpclient", "org/apache/httpcomponents/httpcore",
    "org/apache/httpcomponents/httpasyncclient", "org/apache/httpcomponents/httpcore-nio",
    "commons-codec/commons-codec", "commons-logging/commons-logging",
    "com/github/spullara/mustache/java/compiler", "com/google/guava/guava",
    "org/bouncycastle/bcprov-jdk15on", "org/bouncycastle/bcprov-jdk18on", "org/bouncycastle/bcpkix-jdk18on",
    "org/bouncycastle/bcpg-jdk18on", "com/unboundid/unboundid-ldapsdk", "org/apache/santuario/xmlsec",
    "com/maxmind/geoip2/geoip2", "com/maxmind/db/maxmind-db", "org/jruby/joni/joni", "org/jruby/jcodings/jcodings",
    "org/antlr/antlr4-runtime", "org/ow2/asm/asm", "org/hdrhistogram/HdrHistogram", "com/carrotsearch/hppc",
    "com/tdunning/t-digest", "org/locationtech/jts/jts-core", "org/locationtech/spatial4j/spatial4j",
    "net/sf/jopt-simple/jopt-simple", "net/java/dev/jna/jna", "com/sun/mail/javax.mail",
    "com/googlecode/owasp-java-html-sanitizer/owasp-java-html-sanitizer", "org/jline/jline-reader",
    "org/cryptacular/cryptacular", "io/dropwizard/metrics/metrics-core", "org/slf4j/slf4j-api",
]
SHIBBOLETH = "https://build.shibboleth.net/maven/releases/"
SHIBBOLETH_ARTIFACTS = ["org/opensaml/opensaml-core", "net/shibboleth/utilities/java-support"]

REPORT = []


def log(msg):
    print(msg, flush=True)


def warn(msg):
    print("::warning::%s" % msg, flush=True)
    REPORT.append("- warning: %s" % msg)


def get(url, tries=4, accept=None, timeout=120):
    last = None
    for i in range(tries):
        try:
            h = {"User-Agent": UA}
            if accept:
                h["Accept"] = accept
            with urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=timeout) as r:
                return r.read()
        except urllib.error.HTTPError as e:
            last = e
            if e.code in (404, 410):
                raise
            time.sleep(6 * (i + 1) if e.code in (403, 429, 503) else 2 * (i + 1))
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(2 * (i + 1))
    raise last


def save(out, rel, data):
    p = os.path.join(out, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode("utf-8"))


def text_of(cooked):
    t = re.sub(r"<br\s*/?>", "\n", cooked)
    t = re.sub(r"</(p|li|h[1-6]|tr|div|pre)>", "\n", t)
    t = re.sub(r"<li[^>]*>", "- ", t)
    t = re.sub(r"<a [^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>", r"\2 <\1>", t)
    t = re.sub(r"<[^>]+>", "", t)
    t = html.unescape(t)
    return re.sub(r"\n{3,}", "\n\n", t).strip() + "\n"


def part_tarballs(out):
    for name, url, sha in TARBALLS:
        try:
            raw = get(url, timeout=600)
        except Exception as e:  # noqa: BLE001
            warn("%s: %s" % (url, e))
            continue
        got = hashlib.sha256(raw).hexdigest()
        if got != sha:
            warn("%s: SHA-256 %s, the port has %s: not listed" % (url, got, sha))
            continue
        REPORT.append("- %s: %d bytes, SHA-256 as in the port" % (url.rsplit("/", 1)[1], len(raw)))
        rows = []
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as tf:
            for m in tf:
                if not m.isfile():
                    continue
                path = m.name.split("/", 1)[1] if "/" in m.name else m.name
                if name == "elasticsearch" and path.endswith(".jar"):
                    data = tf.extractfile(m).read()
                    coords = []
                    try:
                        with zipfile.ZipFile(io.BytesIO(data)) as z:
                            for zi in z.namelist():
                                if zi.startswith("META-INF/maven/") and zi.endswith("/pom.properties"):
                                    props = dict(l.split("=", 1) for l in z.read(zi).decode("utf-8", "replace").splitlines()
                                                 if "=" in l and not l.startswith("#"))
                                    coords.append("%s:%s:%s" % (props.get("groupId", "?"), props.get("artifactId", "?"),
                                                                props.get("version", "?")))
                            mf = z.read("META-INF/MANIFEST.MF").decode("utf-8", "replace") if "META-INF/MANIFEST.MF" in z.namelist() else ""
                    except zipfile.BadZipFile:
                        mf = ""
                    iv = re.search(r"^Implementation-Version: *(.+)$", mf, re.M)
                    bv = re.search(r"^Bundle-Version: *(.+)$", mf, re.M)
                    rows.append("\t".join([path, str(m.size), hashlib.sha1(data).hexdigest(), ",".join(coords),
                                           (iv.group(1).strip() if iv else ""), (bv.group(1).strip() if bv else "")]))
                elif name == "kibana" and path.endswith("/package.json") and "node_modules/" in path:
                    try:
                        pj = json.loads(tf.extractfile(m).read().decode("utf-8", "replace"))
                    except Exception:  # noqa: BLE001
                        continue
                    if not isinstance(pj, dict) or not pj.get("name") or not pj.get("version"):
                        continue
                    rows.append("\t".join([path, str(pj.get("name")), str(pj.get("version")),
                                           "1" if pj.get("_inBundle") else ""]))
                elif name == "kibana" and path in ("package.json", "x-pack/package.json",
                                                    "node_modules/x-pack/package.json"):
                    save(out, "tarballs/kibana-%s" % path.replace("/", "_"), tf.extractfile(m).read())
        head = "path\tsize\tsha1\tmaven\timplementation-version\tbundle-version" if name == "elasticsearch" \
            else "path\tname\tversion\tin-bundle"
        save(out, "tarballs/%s-6.8.23.tsv" % name, head + "\n" + "\n".join(sorted(rows)) + "\n")
        REPORT.append("  %d rows in tarballs/%s-6.8.23.tsv" % (len(rows), name))


def part_esa(out):
    topics, page = [], 0
    while page < 60:
        try:
            d = json.loads(get(ESA_CATEGORY % page))
        except Exception as e:  # noqa: BLE001
            warn("ESA page %d: %s" % (page, e))
            break
        tl = (d.get("topic_list") or {}).get("topics") or []
        if not tl:
            break
        topics += tl
        if not (d.get("topic_list") or {}).get("more_topics_url"):
            break
        page += 1
        time.sleep(1)
    seen, rows = set(), []
    for t in topics:
        if t["id"] in seen:
            continue
        seen.add(t["id"])
        try:
            d = json.loads(get(ESA_TOPIC % (t.get("slug", "x"), t["id"])))
            post = (d.get("post_stream") or {}).get("posts") or [{}]
            body = text_of(post[0].get("cooked", ""))
        except Exception as e:  # noqa: BLE001
            warn("ESA topic %s: %s" % (t["id"], e))
            body = ""
        save(out, "esa/%d-%s.txt" % (t["id"], t.get("slug", "x")[:80]),
             "# %s\n# %s\n# https://discuss.elastic.co/t/%s/%d\n\n%s" % (t.get("title", ""), t.get("created_at", ""),
                                                                           t.get("slug", "x"), t["id"], body))
        cves = sorted(set(re.findall(r"CVE-\d{4}-\d{4,}", body + " " + t.get("title", ""))))
        rows.append("\t".join([t.get("created_at", "")[:10], str(t["id"]), t.get("title", "").replace("\t", " "),
                               " ".join(cves)]))
        time.sleep(0.5)
    save(out, "esa/index.tsv", "created\tid\ttitle\tcves\n" + "\n".join(sorted(rows, reverse=True)) + "\n")
    REPORT.append("- ESA: %d topics (esa/index.tsv)" % len(rows))


def part_nvd(out):
    for cpe in NVD_CPES:
        items, start = [], 0
        while True:
            try:
                d = json.loads(get(NVD % (urllib.parse.quote(cpe, safe=":"), start)))
            except Exception as e:  # noqa: BLE001
                warn("NVD %s: %s" % (cpe, e))
                break
            for v in d.get("vulnerabilities", []):
                c = v.get("cve", {})
                items.append({"id": c.get("id"), "published": c.get("published"), "lastModified": c.get("lastModified"),
                              "description": next((x["value"] for x in c.get("descriptions", []) if x.get("lang") == "en"), ""),
                              "configurations": c.get("configurations", []),
                              "metrics": {k: [m.get("cvssData", {}).get("baseScore") for m in vv]
                                          for k, vv in (c.get("metrics") or {}).items()},
                              "references": [r.get("url") for r in c.get("references", [])][:20]})
            start += d.get("resultsPerPage", 0) or 2000
            if start >= d.get("totalResults", 0):
                break
            time.sleep(7)
        save(out, "nvd/%s.json" % cpe.split(":")[4], json.dumps(items, indent=1, ensure_ascii=False))
        REPORT.append("- NVD %s: %d CVEs" % (cpe, len(items)))
        time.sleep(7)


def part_redhat(out):
    cves = set()
    for p in RH_PACKAGES:
        try:
            raw = get("%s/cve.json?package=%s&per_page=2000" % (RH_API, urllib.parse.quote(p, safe="")))
        except Exception as e:  # noqa: BLE001
            warn("Red Hat package %s: %s" % (p, e))
            continue
        save(out, "redhat/package-%s.json" % p.replace("/", "_"), raw)
        try:
            lst = json.loads(raw)
        except Exception:  # noqa: BLE001
            lst = []
        cves.update(x.get("CVE") for x in lst if isinstance(x, dict) and x.get("CVE"))
        REPORT.append("- Red Hat package %s: %d CVEs" % (p, len(lst) if isinstance(lst, list) else 0))
        time.sleep(1)
    for c in sorted(cves):
        try:
            d = json.loads(get("%s/cve/%s.json" % (RH_API, c)))
        except Exception as e:  # noqa: BLE001
            warn("Red Hat %s: %s" % (c, e))
            continue
        keep = {k: d.get(k) for k in ("name", "threat_severity", "public_date", "bugzilla", "details", "statement",
                                       "mitigation", "affected_release", "package_state", "upstream_fix")}
        save(out, "redhat/cve/%s.json" % c, json.dumps(keep, indent=1, ensure_ascii=False))
        time.sleep(0.5)
    REPORT.append("- Red Hat: %d CVEs saved (redhat/cve/)" % len(cves))
    for base in RH_MAVEN:
        label = "ga" if "/ga/" in base else "earlyaccess"
        for art in RH_ARTIFACTS:
            try:
                meta = get(base + art + "/maven-metadata.xml").decode("utf-8", "replace")
            except Exception as e:  # noqa: BLE001
                REPORT.append("- Red Hat Maven %s %s: %s" % (label, art, e))
                continue
            save(out, "redhat/maven-%s/%s/maven-metadata.xml" % (label, art), meta)
            versions = re.findall(r"<version>([^<]+)</version>", meta)
            REPORT.append("- Red Hat Maven %s %s: %s" % (label, art, " ".join(versions[-12:])))
            aid = art.rsplit("/", 1)[1]
            for v in versions:
                if "redhat" not in v:
                    continue
                try:
                    pom = get("%s%s/%s/%s-%s.pom" % (base, art, v, aid, v))
                    save(out, "redhat/maven-%s/%s/%s/%s-%s.pom" % (label, art, v, aid, v), pom)
                except Exception as e:  # noqa: BLE001
                    REPORT.append("  %s %s pom: %s" % (art, v, e))


def part_maven(out):
    for base, arts in ((MAVEN_CENTRAL, MAVEN_ARTIFACTS), (SHIBBOLETH, SHIBBOLETH_ARTIFACTS)):
        for art in arts:
            try:
                meta = get(base + art + "/maven-metadata.xml").decode("utf-8", "replace")
            except Exception as e:  # noqa: BLE001
                warn("Maven %s: %s" % (art, e))
                continue
            save(out, "maven/%s/maven-metadata.xml" % art, meta)
            time.sleep(0.3)
    REPORT.append("- Maven: metadata of %d artifacts" % (len(MAVEN_ARTIFACTS) + len(SHIBBOLETH_ARTIFACTS)))


def part_urls(out, urls):
    for u in urls:
        p = urllib.parse.urlparse(u)
        if p.scheme != "https":
            warn("%s: not https" % u)
            continue
        rel = re.sub(r"[^A-Za-z0-9._/-]", "_", (p.netloc + p.path + ("_" + p.query if p.query else "")).strip("/"))
        if rel.endswith("/") or "." not in rel.rsplit("/", 1)[-1]:
            rel += "/index.html" if not p.query else ".out"
        try:
            data = get(u)
        except Exception as e:  # noqa: BLE001
            warn("%s: %s" % (u, e))
            continue
        save(out, "urls/" + rel, data)
        REPORT.append("- %s: %d bytes (urls/%s)" % (u, len(data), rel))


def part_githist(out, items):
    for item in items:
        m = re.match(r"^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)@(\d{4}-\d{2}-\d{2}):(.+)$", item)
        if not m:
            warn("githist %s: not <owner>/<repo>@<YYYY-MM-DD>:<paths>" % item)
            continue
        repo, since, paths = m.group(1), m.group(2), m.group(3).split(",")
        work = tempfile.mkdtemp()
        d = os.path.join(work, "r")
        r = subprocess.run(["git", "clone", "-q", "--filter=blob:none", "--no-checkout", "--single-branch",
                            "--shallow-since=%s" % since, "https://github.com/%s" % repo, d],
                           capture_output=True, text=True)
        if r.returncode:
            warn("githist %s: clone: %s" % (repo, (r.stderr or r.stdout).strip()[-300:]))
            shutil.rmtree(work, ignore_errors=True)
            continue
        label = repo.replace("/", "_")
        idx = subprocess.run(["git", "-C", d, "log", "--format=%H %ad %an: %s", "--date=short", "--"] + paths,
                             capture_output=True, text=True).stdout
        save(out, "githist/%s/index.txt" % label, "# %s since %s: %s\n%s" % (repo, since, " ".join(paths), idx))
        lg = subprocess.run(["git", "-C", d, "log", "--format=commit %H%nDate: %ad%nAuthor: %an <%ae>%n%n%B",
                             "--date=iso", "--stat", "-p", "--"] + paths, capture_output=True).stdout
        if len(lg) > 40 * 1024 * 1024:
            lg = lg[:40 * 1024 * 1024] + b"\n[cut at 40 MB]\n"
        save(out, "githist/%s/log.txt" % label, lg)
        head = subprocess.run(["git", "-C", d, "log", "-1", "--format=%H %cd", "--date=iso"],
                              capture_output=True, text=True).stdout.strip()
        REPORT.append("- githist %s since %s (%s): %d commits; head %s" % (repo, since, " ".join(paths),
                                                                        len(idx.splitlines()), head))
        shutil.rmtree(work, ignore_errors=True)


def push(out, day, run):
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
            dst = os.path.join(repo, target)
            for part in sorted(os.listdir(out)):
                if os.path.exists(os.path.join(dst, part)):
                    shutil.rmtree(os.path.join(dst, part))
                shutil.copytree(os.path.join(out, part), os.path.join(dst, part))
            git("add", "-A", target, cwd=repo)
            if not git("status", "--porcelain", cwd=repo).stdout.strip():
                log("runs: nothing new to commit")
                return True
            git("-c", "user.name=github-actions[bot]",
                "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
                "commit", "-q", "-m", "es6-fetch: %s (run %s)" % (" ".join(sorted(os.listdir(out))), run), cwd=repo)
            if git("push", "-q", "origin", "HEAD:runs", cwd=repo, check=False).returncode == 0:
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
    ap.add_argument("--parts", default="tarballs esa nvd redhat maven")
    ap.add_argument("--urls", default="")
    ap.add_argument("--githist", default="")
    ap.add_argument("--push", action="store_true")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    day = time.strftime("%Y-%m-%d", time.gmtime())
    parts = a.parts.split()
    REPORT.append("### Elasticsearch 6.8 and Kibana 6.8 fetch (%s)" % " ".join(
        parts + (["urls"] if a.urls.split() else []) + (["githist"] if a.githist.split() else [])))
    REPORT.append("")
    for name, fn in (("tarballs", part_tarballs), ("esa", part_esa), ("nvd", part_nvd), ("redhat", part_redhat),
                     ("maven", part_maven)):
        if name in parts:
            log("== %s" % name)
            try:
                fn(a.out)
            except Exception as e:  # noqa: BLE001
                warn("%s: %s" % (name, e))
    if a.urls.split():
        log("== urls")
        part_urls(a.out, a.urls.split())
    if a.githist.split():
        log("== githist")
        part_githist(a.out, a.githist.split())
    ok = True
    if a.push:
        ok = push(a.out, day, os.environ.get("GITHUB_RUN_ID", "0"))
        REPORT.append("")
        REPORT.append("Files: branch runs of azsupport/azsupport, `%s/%s/`%s." % (RUNS_DIR, day, "" if ok else " (push failed)"))
    if a.report:
        with open(a.report, "w", encoding="utf-8") as f:
            f.write("\n".join(REPORT) + "\n")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
