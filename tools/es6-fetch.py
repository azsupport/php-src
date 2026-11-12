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
  probe      Elasticsearch 6.8.23 of the tarball started here (JDK 17 of the
             runner, one node), and search requests whose query text is what a
             visitor of a site could type into a search box that goes into a
             query_string or simple_query_string query: deep nesting of
             parentheses, field patterns of many wildcards, nested regular
             expressions; for each, the answer and whether the node survived
             (a StackOverflowError ends the JVM of Elasticsearch)
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
ES_TARBALL = {}


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
        if name == "elasticsearch":
            ES_TARBALL["raw"] = raw
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


def es_http(method, path, body=None, timeout=90):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request("http://127.0.0.1:9200" + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace"), time.time() - t0
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace"), time.time() - t0
    except Exception as e:  # noqa: BLE001
        return 0, "%s: %s" % (type(e).__name__, e), time.time() - t0


def es_start(home, logf, java_home, extra):
    env = dict(os.environ, JAVA_HOME=java_home, ES_JAVA_OPTS="-Xms512m -Xmx512m " + extra,
               ES_TMPDIR=os.path.join(home, "tmp"))
    os.makedirs(env["ES_TMPDIR"], exist_ok=True)
    proc = subprocess.Popen([os.path.join(home, "bin", "elasticsearch")], env=env, stdout=logf,
                            stderr=subprocess.STDOUT, cwd=home)
    for _ in range(180):
        if proc.poll() is not None:
            return proc, False
        st, body, _t = es_http("GET", "/_cluster/health?wait_for_status=yellow&timeout=1s", timeout=5)
        if st == 200:
            return proc, True
        time.sleep(1)
    return proc, False


def nest(n):
    return "(" * n + "a" + ")" * n


# the JVMs the probes run on: (label, JAVA_HOME variable of the runner, more ES_JAVA_OPTS)
PROBE_CONFIGS = [("17", "JAVA_HOME_17_X64", ""), ("21", "JAVA_HOME_21_X64", "-Djava.security.manager=allow"),
                 ("17 -Xss4m", "JAVA_HOME_17_X64", "-Xss4m")]

# (name, kind, query text); the configs labelled with -Xss only run those marked "xss"
PROBES = [
    ("query_string, (((a))) nesting 1000", "query_string", nest(1000)),
    ("query_string, (((a))) nesting 2000", "query_string", nest(2000)),
    ("query_string, (((a))) nesting 3000", "query_string", nest(3000)),
    ("query_string, (((a))) nesting 4000", "query_string", nest(4000)),
    ("query_string, (((a))) nesting 5000", "query_string", nest(5000)),
    ("query_string, (((a))) nesting 15000", "query_string", nest(15000)),
    ("query_string, field pattern of 5000 escaped \\* (\\*\\*...:a)", "query_string", "\\*" * 5000 + ":a"),
    ("query_string, field pattern of 20000 escaped \\* (\\*\\*...:a)", "query_string", "\\*" * 20000 + ":a"),
    ("query_string, field pattern \\*a\\*a... of 3000 parts", "query_string", "\\*t" * 3000 + ":a"),
    ("query_string, field pattern of 500 *", "query_string", "*" * 500 + ":a"),
    ("query_string, field pattern of 1000 *", "query_string", "*" * 1000 + ":a"),
    ("query_string, field pattern of 2000 *", "query_string", "*" * 2000 + ":a"),
    ("query_string, field pattern of 5000 *", "query_string", "*" * 5000 + ":a"),
    ("query_string, a term of 5000 * (no field)", "query_string", "a" + "*" * 5000),
    ("query_string, a*a*a... term of 2000 parts", "query_string", "a*" * 2000),
    ("query_string, regexp /(((a)))/ nesting 2000", "query_string", "/" + nest(2000) + "/"),
    ("query_string, regexp /a{1,30000}/", "query_string", "/a{1,30000}/"),
    ("query_string, fuzzy of a 300 letter term", "query_string", "a" * 300 + "~2"),
    ("simple_query_string, (((a))) nesting 2000", "simple_query_string", nest(2000)),
    ("simple_query_string, (((a))) nesting 15000", "simple_query_string", nest(15000)),
    ("simple_query_string, flags NONE, nesting 15000", "simple_query_string_none", nest(15000)),
    ("query_string, regexp /a{1000}{1000}{1000}/ (stacked repeats)", "query_string", "/a{1000}{1000}{1000}/"),
    ("query_string, regexp /a+++.../ (500 stacked +)", "query_string", "/a" + "+" * 500 + "/"),
    ("range on a long field, gte 1e-100000000", "range_long", "1e-100000000"),
    ("index a document, long field 1e-100000000", "index_long", "1e-100000000"),
    ("match, the same text of 15000 (((a)))", "match", nest(15000)),
    ("multi_match, the same text of 15000 (((a)))", "multi_match", nest(15000)),
]
XSS_PROBES = {"query_string, (((a))) nesting 5000", "query_string, (((a))) nesting 15000",
              "simple_query_string, (((a))) nesting 15000", "query_string, field pattern of 5000 *"}


def part_probe(out):
    raw = ES_TARBALL.get("raw")
    if raw is None:
        url, sha = TARBALLS[0][1], TARBALLS[0][2]
        raw = get(url, timeout=600)
        if hashlib.sha256(raw).hexdigest() != sha:
            warn("probe: the tarball is not that of the port")
            return
    base = tempfile.mkdtemp()
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as tf:
        tf.extractall(base)
    home = os.path.join(base, "elasticsearch-6.8.23")
    with open(os.path.join(home, "config", "elasticsearch.yml"), "a") as f:
        f.write("\ndiscovery.type: single-node\nxpack.ml.enabled: false\nhttp.port: 9200\n")
    rows, logs = [], []
    for jdk, var, extra in PROBE_CONFIGS:
        java_home = os.environ.get(var)
        if not java_home:
            warn("probe: no %s on this runner" % var)
            continue
        logpath = os.path.join(base, "es-jdk%s.log" % jdk)
        logf = open(logpath, "ab")
        proc, up = es_start(home, logf, java_home, extra)
        if not up:
            warn("probe: Elasticsearch 6.8.23 on JDK %s did not start" % jdk)
            logf.close()
            logs.append((jdk, logpath))
            if proc.poll() is None:
                proc.kill()
            continue
        es_http("PUT", "/probe", {"settings": {"number_of_shards": 1, "number_of_replicas": 0},
                                  "mappings": {"_doc": {"properties": {"title": {"type": "text"},
                                                                       "description": {"type": "text"},
                                                                       "tags": {"type": "keyword"},
                                                                       "n": {"type": "long"}}}}})
        es_http("PUT", "/probe/_doc/1?refresh=true", {"title": "a video about cats", "description": "cats and dogs",
                                                     "tags": ["cats"], "n": 5})
        probes = [p for p in PROBES if "-Xss" not in jdk or p[0] in XSS_PROBES]
        if os.environ.get("PROBE_FILTER"):
            probes = [p for p in probes if re.search(os.environ["PROBE_FILTER"], p[0])]
        for name, kind, text in probes:
            if kind == "match":
                q = {"match": {"title": text}}
            elif kind == "simple_query_string_none":
                q = {"simple_query_string": {"query": text, "flags": "NONE"}}
            elif kind == "range_long":
                q = {"range": {"n": {"gte": text}}}
            elif kind == "multi_match":
                q = {"multi_match": {"query": text, "fields": ["title", "description"]}}
            else:
                q = {kind: {"query": text}}
            if kind == "index_long":
                st, body, took = es_http("PUT", "/probe/_doc/2", {"title": "x", "n": text}, timeout=180)
            else:
                st, body, took = es_http("POST", "/probe/_search", {"query": q}, timeout=180)
            time.sleep(2)
            died = proc.poll() is not None
            alive = (not died) and es_http("GET", "/", timeout=10)[0] == 200
            if not alive and not died:
                time.sleep(5)
                died = proc.poll() is not None
            m = re.search(r'"reason":"([^"]{0,200})', body) or re.search(r'"type":"([^"]{0,120})', body)
            rows.append("| %s | %s | %d chars | %s | %.2f s | %s | %s |" % (
                jdk, name, len(text), st, took, (m.group(1) if m else body[:120]).replace("|", "/"),
                "died (exit %s)" % proc.returncode if died else ("alive" if alive else "no answer")))
            if died or not alive:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()
                proc, up = es_start(home, logf, java_home, extra)
                if not up:
                    warn("probe: Elasticsearch did not start again after %s (JDK %s)" % (name, jdk))
                    break
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=60)
            except subprocess.TimeoutExpired:
                proc.kill()
        logf.close()
        logs.append((jdk, logpath))
    md = ["# Elasticsearch 6.8.23: search requests with query text a visitor could type", "",
          "The tarball of Elastic (that of textproc/elasticsearch6), one node, the JDK of the runner, -Xss of its"
          " jvm.options (1m), heap 512m; index probe with one document. A node that died was started again.", "",
          "| JDK | query | size | HTTP | took | reason | node |", "|---|---|---|---|---|---|---|"] + rows
    save(out, "probe/results.md", "\n".join(md) + "\n")
    for jdk, lp in logs:
        try:
            data = open(lp, "rb").read()
        except OSError:
            continue
        text = data.decode("utf-8", "replace").splitlines()
        keep = []
        for i, l in enumerate(text):
            if re.search(r"fatal|StackOverflow|OutOfMemory|exiting|ERROR|started|Exception", l):
                keep.append(l)
                if re.search(r"StackOverflowError|OutOfMemoryError", l):
                    keep.extend(text[i + 1:i + 25])
        save(out, "probe/es-jdk%s.log" % jdk, "\n".join(keep[-400:]) + "\n")
    REPORT.append("- probe: %d requests (probe/results.md)" % len(rows))
    REPORT.extend(["", "| JDK | query | size | HTTP | took | reason | node |", "|---|---|---|---|---|---|---|"] + rows + [""])
    if not os.environ.get("PROBE_FILTER") or re.search(os.environ["PROBE_FILTER"], "two nodes"):
        cluster_probe(out, home, base)
    shutil.rmtree(base, ignore_errors=True)


def cluster_probe(out, home, base):
    """Two nodes of one cluster, an index of one shard with one replica, and one request with 5000
    nested parentheses in query_string sent to the first node: does a failed copy of the shard take
    the other copy down too (the search goes on to the next copy of a failed shard)?"""
    java_home = os.environ.get("JAVA_HOME_17_X64")
    if not java_home:
        return
    procs, lines = [], []
    for i in (0, 1):
        h = os.path.join(base, "node%d" % i)
        shutil.copytree(home, h, symlinks=True, ignore=shutil.ignore_patterns("data", "logs", "tmp"))
        os.makedirs(os.path.join(h, "logs"), exist_ok=True)
        with open(os.path.join(h, "config", "elasticsearch.yml"), "w") as f:
            f.write("cluster.name: probe2\nnode.name: n%d\nxpack.ml.enabled: false\nhttp.port: %d\n"
                    "transport.tcp.port: %d\ndiscovery.zen.ping.unicast.hosts: [\"127.0.0.1:9310\", \"127.0.0.1:9311\"]\n"
                    "discovery.zen.minimum_master_nodes: 1\nnetwork.host: 127.0.0.1\n" % (i, 9210 + i, 9310 + i))
        env = dict(os.environ, JAVA_HOME=java_home, ES_JAVA_OPTS="-Xms384m -Xmx384m",
                   ES_TMPDIR=os.path.join(h, "tmp"))
        os.makedirs(env["ES_TMPDIR"], exist_ok=True)
        logf = open(os.path.join(base, "node%d.log" % i), "ab")
        procs.append(subprocess.Popen([os.path.join(h, "bin", "elasticsearch")], env=env, stdout=logf,
                                      stderr=subprocess.STDOUT, cwd=h))

    def call(port, method, path, body=None, timeout=60):
        data = json.dumps(body).encode("utf-8") if body is not None else None
        req = urllib.request.Request("http://127.0.0.1:%d%s" % (port, path), data=data, method=method,
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status, r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")
        except Exception as e:  # noqa: BLE001
            return 0, "%s: %s" % (type(e).__name__, e)

    ok = False
    for _ in range(180):
        st, body = call(9210, "GET", "/_cluster/health?wait_for_nodes=2&timeout=1s", timeout=5)
        if st == 200 and '"number_of_nodes":2' in body:
            ok = True
            break
        time.sleep(1)
    if not ok:
        lines.append("the two nodes did not form a cluster: %s" % body[:200])
    else:
        call(9210, "PUT", "/probe", {"settings": {"number_of_shards": 1, "number_of_replicas": 1},
                                     "mappings": {"_doc": {"properties": {"title": {"type": "text"}}}}})
        call(9210, "PUT", "/probe/_doc/1?refresh=true", {"title": "cats"})
        st, body = call(9210, "GET", "/_cluster/health/probe?wait_for_status=green&timeout=60s", timeout=70)
        lines.append("index probe: 1 shard, 1 replica: %s" % ("green" if '"status":"green"' in body else body[:200]))
        st, body = call(9210, "GET", "/_cat/shards/probe?h=prirep,node", timeout=10)
        lines.append("copies: %s" % " ".join(body.split()))
        for attempt in (1, 2):
            if procs[0].poll() is not None and procs[1].poll() is not None:
                break
            port = 9210 if procs[0].poll() is None else 9211
            st, body = call(port, "POST", "/probe/_search", {"query": {"query_string": {"query": nest(5000)}}})
            time.sleep(8)
            lines.append("request %d (5000 nested parentheses, sent to the node of port %d): HTTP %s; node n0 %s, node n1 %s"
                         % (attempt, port, st, "died (exit %s)" % procs[0].returncode if procs[0].poll() is not None else "alive",
                            "died (exit %s)" % procs[1].returncode if procs[1].poll() is not None else "alive"))
    for p in procs:
        if p.poll() is None:
            p.terminate()
            try:
                p.wait(timeout=60)
            except subprocess.TimeoutExpired:
                p.kill()
    for i in (0, 1):
        try:
            data = open(os.path.join(base, "node%d.log" % i), "rb").read().decode("utf-8", "replace")
        except OSError:
            continue
        keep = [l for l in data.splitlines() if re.search(r"fatal|StackOverflow|OutOfMemory|exiting|failed|ERROR|WARN", l)]
        save(out, "probe/cluster-n%d.log" % i, "\n".join(keep[-200:]) + "\n")
    save(out, "probe/cluster.md", "# Two nodes, one shard with a replica, 5000 nested parentheses in query_string\n\n"
         + "\n".join("- " + l for l in lines) + "\n")
    REPORT.append("- probe, two nodes:")
    REPORT.extend("  - " + l for l in lines)


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
                     ("maven", part_maven), ("probe", part_probe)):
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
