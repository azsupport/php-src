#!/bin/sh
# curl-test.sh - test the curl program of /usr/local/az (tools/build-deps.sh, the
# line "program curl" of freebsd/deps.conf): the version and features of the
# bundled curl (freebsd/curl/build-libcurl.sh: the OpenSSL of the tree, c-ares,
# HTTP/2, brotli, zstd, IDN, the Public Suffix List; no IMAP, POP3, SMTP, LDAP,
# telnet, TFTP, DICT, gopher, MQTT, RTSP), a file:// read, and an https:// request
# to github.com (HTTP/2, the CA store of the base system).
#
# Usage (FreeBSD, after tools/build-deps.sh): sh tools/curl-test.sh
# Results: curl-results/tests.txt (one line per check, the summary at the end);
# exit status 0 when every check passed.

set -u
top="$(pwd)"
A="${AZ_PREFIX:-/usr/local/az}"
res="$top/curl-results"
T="${CURL_TEST_WORK:-/var/tmp/curl-test}"
c="$A/bin/curl"
mkdir -p "$res"
rm -rf "$T"; mkdir -p "$T"
out="$res/tests.txt"
: > "$out"
ok=0; bad=0
pass() { echo "ok    $*" >> "$out"; ok=$((ok + 1)); }
fail() { echo "FAIL  $*" >> "$out"; bad=$((bad + 1)); }
finish() {
    echo "tests: $ok ok, $bad failed" >> "$out"
    cat "$out"
    [ "$bad" = 0 ]
    exit $?
}

[ -x "$c" ] || { fail "no $c (tools/build-deps.sh first)"; finish; }
"$c" --version > "$T/version.txt" 2>&1 || { fail "curl --version: $(head -n 2 "$T/version.txt" | tr '\n' ' ')"; finish; }
first="$(head -n 1 "$T/version.txt")"
feats=" $(sed -n 's/^Features: //p' "$T/version.txt") "
protos=" $(sed -n 's/^Protocols: //p' "$T/version.txt") "
case "$first" in *"OpenSSL/3."*) pass "TLS: $(echo "$first" | grep -o 'OpenSSL/[^ ]*')" ;; *) fail "not the OpenSSL 3 of the tree: $first" ;; esac
case "$first" in *"c-ares/"*) pass "resolver: $(echo "$first" | grep -o 'c-ares/[^ ]*')" ;; *) fail "no c-ares: $first" ;; esac
miss=""
for f in alt-svc AsynchDNS brotli HSTS HTTP2 HTTPS-proxy IDN IPv6 libz PSL SSL zstd; do
    case "$feats" in *" $f "*) ;; *) miss="$miss $f" ;; esac
done
if [ -z "$miss" ]; then pass "features:$feats"; else fail "features missing:$miss (have:$feats)"; fi
extra=""
for p in dict gopher imap imaps ldap ldaps mqtt pop3 pop3s rtsp smtp smtps telnet tftp; do
    case "$protos" in *" $p "*) extra="$extra $p" ;; esac
done
miss=""
for p in file ftp ftps http https; do
    case "$protos" in *" $p "*) ;; *) miss="$miss $p" ;; esac
done
if [ -z "$miss$extra" ]; then pass "protocols:$protos"; else fail "protocols:$protos (missing:${miss:- -}; not wanted:${extra:- -})"; fi
libs="$(ldd "$c" | awk 'NR > 1 { print $3 }' | tr '\n' ' ')"
case "$libs" in *"/usr/local/"*) fail "links a library of /usr/local: $libs" ;; *) pass "libraries of the base system only: $libs" ;; esac
echo "a line of a file" > "$T/file.txt"
if [ "$("$c" -sS "file://$T/file.txt" 2>&1)" = "a line of a file" ]; then pass "file:// reads a local file"
else fail "file://: $("$c" -sS "file://$T/file.txt" 2>&1 | head -n 2 | tr '\n' ' ')"; fi
r="$("$c" -sS -o /dev/null --max-time 60 -w '%{http_code} %{http_version} %{ssl_verify_result}' https://github.com/ 2>&1)"
case "$r" in
    "200 2 0"|"301 2 0"|"302 2 0") pass "https://github.com/: status, HTTP version, verification: $r" ;;
    *) fail "https://github.com/: $r" ;;
esac
finish
