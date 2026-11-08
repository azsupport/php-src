#!/bin/sh
# curl-test.sh - test the package curl of tools/build-az.sh, installed in the place
# of that of the ports (tools/build-deps.sh, build_curl_program; the line "program
# curl" of freebsd/deps.conf): its version and features, those of the port ftp/curl
# (the OpenSSL of /usr/local/azsupport/static, the threaded resolver, HTTP/2, brotli, zstd, IDN,
# the Public Suffix List, NTLM; the protocols of the port: DICT, FTP, gopher, HTTP,
# IMAP, IPFS, MQTT, POP3, RTSP, SMTP, telnet, TFTP, WebSocket; no LDAP, SCP and
# SFTP), a file:// read, an https:// request to
# github.com (HTTP/2, the CA store of the base system), and libcurl.so: with the
# libraries of the base system only, and taken by git (git ls-remote over https).
#
# Usage (FreeBSD, the package curl installed): sh tools/curl-test.sh
# Results: curl-results/tests.txt (one line per check, the summary at the end);
# exit status 0 when every check passed.

set -u
top="$(pwd)"
res="$top/curl-results"
T="${CURL_TEST_WORK:-/var/tmp/curl-test}"
c="${CURL_PREFIX:-/usr/local}/bin/curl"
so="${CURL_PREFIX:-/usr/local}/lib/libcurl.so.4"
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
# the threaded resolver of the port (AsynchDNS among the features), not c-ares (the curl of PHP)
case "$first" in *"c-ares/"*) fail "c-ares: the package curl has the threaded resolver of the port: $first" ;; *) pass "resolver: threaded" ;; esac
miss=""
for f in alt-svc AsynchDNS brotli HSTS HTTP2 HTTPS-proxy IDN IPv6 libz NTLM PSL SSL zstd; do
    case "$feats" in *" $f "*) ;; *) miss="$miss $f" ;; esac
done
if [ -z "$miss" ]; then pass "features:$feats"; else fail "features missing:$miss (have:$feats)"; fi
extra=""
for p in ldap ldaps scp sftp; do
    case "$protos" in *" $p "*) extra="$extra $p" ;; esac
done
miss=""
for p in dict file ftp ftps gopher gophers http https imap imaps ipfs ipns mqtt pop3 pop3s rtsp smtp smtps telnet tftp ws wss; do
    case "$protos" in *" $p "*) ;; *) miss="$miss $p" ;; esac
done
if [ -z "$miss$extra" ]; then pass "protocols:$protos"; else fail "protocols:$protos (missing:${miss:- -}; not wanted:${extra:- -})"; fi
libs="$(ldd "$c" | awk 'NR > 1 { print $3 }' | tr '\n' ' ')"
case "$libs" in *"/usr/local/"*) fail "links a library of /usr/local: $libs" ;; *) pass "libraries of the base system only: $libs" ;; esac
echo "a line of a file" > "$T/file.txt"
if [ "$("$c" -sS "file://$T/file.txt" 2>&1)" = "a line of a file" ]; then pass "file:// reads a local file"
else fail "file://: $("$c" -sS "file://$T/file.txt" 2>&1 | head -n 2 | tr '\n' ' ')"; fi
# up to three tries: on 08.11.2026 GitHub did not answer the VM for 60 s, git over https a minute later did
r="$("$c" -sS -o /dev/null --max-time 60 --retry 2 --retry-all-errors --retry-delay 10 -w '%{http_code} %{http_version} %{ssl_verify_result}' https://github.com/ 2>&1)"
case "$r" in
    "200 2 0"|"301 2 0"|"302 2 0") pass "https://github.com/: status, HTTP version, verification: $r" ;;
    *) fail "https://github.com/: $r" ;;
esac
# libcurl.so: the libraries of the base system only, the API of curl only
if [ -f "$so" ]; then
    l="$(ldd "$so" 2>/dev/null | awk 'NF > 2 && $2 == "=>" { print $3 }' | tr '\n' ' ')"
    case "$l" in *"/usr/local/"*) fail "libcurl.so.4 links a library of /usr/local: $l" ;; *) pass "libcurl.so.4: $l" ;; esac
    x="$(nm -D --defined-only "$so" | awk 'NF >= 3 && $3 !~ /^(curl_|_init$|_fini$|_edata$|_end$|__bss_start$)/' | head -n 3 | tr '\n' ' ')"
    n="$(nm -D --defined-only "$so" | grep -c ' curl_')"
    miss=""
    for f in curl_global_init curl_easy_init curl_easy_setopt curl_easy_perform curl_multi_perform curl_version_info; do
        nm -D --defined-only "$so" | grep -q " $f\$" || miss="$miss $f"
    done
    if [ -n "$x" ]; then fail "libcurl.so.4 exports more than curl_*: $x"
    elif [ -n "$miss" ] || [ "$n" -lt 50 ]; then fail "libcurl.so.4 exports $n curl_* functions, missing:${miss:- -}"
    else pass "libcurl.so.4 exports curl_* only ($n functions)"; fi
    # git over https takes it (git-remote-http links libcurl.so.4)
    g="$(ls /usr/local/libexec/git-core/git-remote-http 2>/dev/null)"
    if [ -n "$g" ]; then
        if ldd "$g" 2>/dev/null | grep -q "libcurl.so.4 => $so"; then pass "git-remote-http loads $so"
        else fail "git-remote-http: $(ldd "$g" 2>/dev/null | grep libcurl)"; fi
        if git ls-remote https://github.com/freebsd/freebsd-ports HEAD > "$T/git.txt" 2>&1; then pass "git ls-remote over https: $(cut -c1-12 "$T/git.txt")"
        else fail "git ls-remote: $(tail -n 2 "$T/git.txt" | tr '\n' ' ')"; fi
    else
        echo "note  no git here: libcurl.so.4 not tried with git" >> "$out"
    fi
else
    fail "no $so"
fi
finish
