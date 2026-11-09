#!/bin/sh
# bench.sh - build the CLI of one PHP version from a release tarball of the fork
# with several compilers and kinds of build, and compare their speed with
# Zend/bench.php and Zend/micro_bench.php of the same tree. The GitHub workflow
# .github/workflows/bench.yml runs it in a FreeBSD VM, one job per version; with
# --local it runs on another system too (Linux), with the compilers it finds there.
#
# Usage (from the top of a checkout of master):
#   sh tools/bench.sh --fetch <version> <dir>   the newest dated release tarball of the
#                                               version (freebsd-<version>-<YYYYMMDD>-<commit>)
#                                               into <dir>, its SHA-256 checked against the
#                                               .sha256 of the release (gh, curl: the runner)
#   sh tools/bench.sh --deps                    FreeBSD: pkg install llvm23 and gcc16, or the
#                                               newest llvm<N> and gcc<N> of the repository
#   sh tools/bench.sh [--local] [-r <runs>] <version> <tarball>
#                                               build the variants, run the benchmarks <runs>
#                                               times (default 5), write the report
#
# The variants, all from the same tree with the same ./configure (--disable-all
# --enable-cli --disable-cgi --disable-phpdbg --enable-opcache) and CFLAGS (those of
# the servers, -O3 -pipe -march=x86-64-v3 -fstack-protector-strong -fno-strict-aliasing,
# and -std=gnu17: the default of clang, while GCC 15 and later default to C23, which
# PHP 7.4 does not build with); <N> is the major version of the compiler:
#   clang<N>          the base cc (FreeBSD 15.1: clang 19): the baseline of the report
#   clang<N>-pgo      the same with PGO: built with -fprofile-generate, the training run
#                     (below), llvm-profdata merge (the base one, or that of the llvm
#                     package when the base has none), rebuilt with -fprofile-use
#   clang<M>          clang of the newest llvm package (llvm23); when that is the
#                     version of the base cc (--local), its variants stand for the base's
#   clang<M>-pgo      the same with PGO, with the llvm-profdata of that package
#   clang<M>-pgo-lto  the profile of clang<M>-pgo, rebuilt with ThinLTO (-flto=thin),
#                     linked by the ld.lld of that package
#   gcc<K>            GCC of the packages (gcc16): configure finds the global register
#                     variables that the Zend VM keeps its registers in (clang has none)
#   gcc<K>-pgo        the same with PGO (.gcda files; -fprofile-use -fprofile-correction)
#   gcc<K>-nsi        gcc<K> with -fno-semantic-interposition, in a tree of its own (the
#                     CFLAGS of its configure): with -fPIC (a shared libphp) GCC takes
#                     every exported function (ZEND_API, PHPAPI: visibility default even
#                     with -fvisibility=hidden) as replaceable at load time, so the engine's
#                     own calls to them go through the PLT and are never inlined; with the
#                     flag it may bind and inline them. The CLI, an executable, is not
#                     affected
#   clang<N>-nsi      the base cc with -fno-semantic-interposition (only when
#                     BENCH_VARIANTS names base-nsi)
# The PGO and LTO flags go in through a response file in PROF_FLAGS, the variable of
# the prof-gen and prof-use targets of build/Makefile.global (make prof-clean between
# the builds): the libtool of PHP passes @file on to the link of opcache.so, where it
# drops -flto and -fuse-ld.
#
# The training run, the same for every PGO variant and never the benchmarks: the
# run-tests.php of the same tree on Zend/tests, ext/standard/tests/strings and
# ext/standard/tests/array (-j<cpus>, SKIP_SLOW_TESTS, SKIP_ONLINE_TESTS), twice:
# without OPcache, then with OPcache (on 8.x with the tracing JIT), so that opcache.so
# has a profile too. Each part ends after BENCH_TRAIN_TIME seconds (default 150): then
# run-tests.php itself is stopped, and the tests that run end by themselves, writing
# their counts.
#
# The benchmarks, each <runs> times, the variants interleaved (one run of each variant,
# then the next round; the order turns from round to round), pinned to the last CPU, in
# three modes:
#   nocache   php -n
#   opcache   -d zend_extension=<opcache.so of the variant> -d opcache.enable_cli=1, on
#             8.x also -d opcache.jit=tracing -d opcache.jit_buffer_size=128M
#   huge      as nocache, with USE_ZEND_ALLOC_HUGE_PAGES=1 (the Zend allocator maps its
#             2 MB chunks with MAP_ALIGNED_SUPER on FreeBSD, MAP_HUGETLB on Linux)
# Through a shared libphp (BENCH_EMBED=1, the input embed of the workflow): every tree
# is configured with --enable-embed=shared too, and each variant runs again through its
# libphp (libs/libphp.so, libphp7.so on 7.x: the embed SAPI, built from the same PIC
# objects as the libphp.so of mod_php) with a driver of a few lines (bench-embed.c,
# written here; no php.ini, as php -n): the variant <name>-embed, interleaved with the
# CLI of the same build, in the modes nocache and huge (OPcache does not run in the
# embed SAPI: it is not one of the SAPIs OPcache supports). The default variants are
# then base gcc gcc-nsi, and the report adds the change of each <name>-embed against
# the CLI of its build and against the -embed of the baseline, as the median of the
# ratios of the runs of one round.
# The report: the median of the "Total" line of each script, in seconds, and its change
# against the baseline in %, for every variant, script and mode; the compilers, the CPU,
# the training. In bench-results/<version>/: report.txt (printed at the end), report.md
# (for the job summary), runs.txt (every run), variants/ (the facts of each variant),
# logs/. Every failure of a build or a run is printed with its reason, and the other
# variants go on.
#
# Environment: BENCH_TRAIN_TIME (seconds per part of the training), BENCH_VARIANTS (a
# part of: base base-pgo base-nsi llvm llvm-pgo llvm-pgo-lto gcc gcc-pgo gcc-nsi),
# BENCH_EMBED=1 (through a shared libphp too), BENCH_CFLAGS (instead of the CFLAGS
# above), BENCH_BASE_CC, BENCH_LLVM_CC, BENCH_GCC (the compilers), BENCH_KEEP=1 (keep
# bench-work/<version>: the build trees and the binaries).
# Exit status: 0 the report has results, 1 no variant ran, 2 usage.

set -u
top="$(pwd)"
repo="${BENCH_REPO:-azsupport/php-src}"
os="$(uname -s)"
say() { printf '[bench %s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
esc="$(printf '\033')"
usage() { sed -n 's/^# \{0,1\}//; 8,17p' "$0" >&2; exit 2; }

sha256_of() {
    if command -v sha256sum > /dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else sha256 -q "$1"; fi
}

# --fetch <version> <dir>
fetch() {
    v="$1"; d="$2"
    case "$v" in ''|*[!0-9.]*) echo "bench: not a PHP version: $v" >&2; return 2 ;; esac
    command -v gh > /dev/null 2>&1 || { echo "bench: --fetch needs gh (the GitHub CLI)" >&2; return 1; }
    mkdir -p "$d" || return 1
    vre="$(printf '%s' "$v" | sed 's/[.]/[.]/g')"
    # the dated releases (freebsd-<v>-latest is a copy of the newest of them), newest first
    tag="$(gh api --paginate "repos/$repo/releases?per_page=100" \
            -q '.[] | select(.draft | not) | "\(.published_at) \(.tag_name)"' |
        grep -E " freebsd-$vre-[0-9]{8}-[0-9a-f]+\$" | sort -r | head -n 1 | cut -d' ' -f2)"
    [ -n "$tag" ] || { echo "bench: no release freebsd-$v-<YYYYMMDD>-<commit> in $repo" >&2; return 1; }
    assets="$(gh api "repos/$repo/releases/tags/$tag" -q '.assets[] | "\(.name) \(.browser_download_url)"')"
    f="$(printf '%s\n' "$assets" | awk '$1 ~ /\.tar\.xz$/ { print $1; exit }')"
    [ -n "$f" ] || { echo "bench: the release $tag has no .tar.xz" >&2; return 1; }
    for n in "$f" "$f.sha256"; do
        u="$(printf '%s\n' "$assets" | awk -v n="$n" '$1 == n { print $2; exit }')"
        [ -n "$u" ] || { echo "bench: the release $tag has no $n" >&2; return 1; }
        rm -f "$d/$n"
        curl -fsSL --retry 4 --retry-all-errors --retry-delay 10 --connect-timeout 30 --max-time 900 \
            -o "$d/$n" "$u" || { echo "bench: download of $u failed" >&2; return 1; }
    done
    want="$(cut -d' ' -f1 < "$d/$f.sha256")"
    got="$(sha256_of "$d/$f")"
    if [ -z "$want" ] || [ "$got" != "$want" ]; then
        echo "bench: $f: SHA-256 $got, not ${want:-?} as in $f.sha256 of $tag" >&2; return 1
    fi
    echo "bench: $tag: $d/$f, SHA-256 $got as in $f.sha256"
}

# --deps: the compilers of the packages, llvm23 and gcc16 or the newest there are;
# bench-work/deps.txt names the packages for the run
deps() {
    [ "$os" = FreeBSD ] || { echo "bench: --deps is for FreeBSD (pkg); --local takes the compilers it finds" >&2; return 2; }
    env ASSUME_ALWAYS_YES=yes pkg update || echo "bench: pkg update failed"
    mkdir -p "$top/bench-work"
    : > "$top/bench-work/deps.txt"
    drc=0
    wants="llvm23 gcc16"
    # the runs through libphp (BENCH_EMBED) need no llvm unless BENCH_VARIANTS names it
    if [ "${BENCH_EMBED:-0}" = 1 ]; then
        case " ${BENCH_VARIANTS:-base gcc gcc-nsi} " in *" llvm"*) ;; *) wants="gcc16" ;; esac
    fi
    for want in $wants; do
        b="${want%%[0-9]*}"
        if pkg info -e "$want" || [ -n "$(pkg rquery '%n' "$want" 2>/dev/null)" ]; then
            name="$want"
        else
            n="$(pkg rquery -x '%n' "^${b}[0-9]+\$" 2>/dev/null | sed "s/^$b//" | sort -n | tail -n 1)"
            if [ -z "$n" ]; then
                echo "bench: neither $want nor any $b<N> is in the package repository"; drc=1; continue
            fi
            name="$b$n"
            echo "bench: $want is not in the package repository; taking $name, the newest $b<N> there"
        fi
        if pkg info -e "$name" || env ASSUME_ALWAYS_YES=yes pkg install -y "$name"; then
            pkg query '%n-%v' "$name" >> "$top/bench-work/deps.txt"
            echo "bench: $(pkg query '%n-%v' "$name") installed"
        else
            echo "bench: pkg install $name failed"; drc=1
        fi
    done
    return $drc
}

case "${1:-}" in
    --fetch) [ $# -eq 3 ] || usage; fetch "$2" "$3"; exit $? ;;
    --deps) deps; exit $? ;;
esac

local=0
runs=5
while [ $# -gt 0 ]; do
    case "$1" in
        --local) local=1; shift ;;
        -r) [ $# -ge 2 ] || usage; runs="$2"; shift 2 ;;
        -*) usage ;;
        *) break ;;
    esac
done
[ $# -eq 2 ] || usage
ver="$1"
case "$ver" in [0-9].[0-9]|[0-9].[0-9][0-9]) ;; *) echo "bench: not a PHP version: $ver" >&2; exit 2 ;; esac
case "$runs" in ''|*[!0-9]*|0) echo "bench: -r wants a number of runs, not $runs" >&2; exit 2 ;; esac
[ -f "$2" ] || { echo "bench: no tarball $2" >&2; exit 2; }
tarball="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
if [ "$local" = 0 ] && [ "$os" != FreeBSD ]; then
    echo "bench: not FreeBSD: --local takes the compilers it finds here" >&2; exit 2
fi
major="${ver%%.*}"
train_time="${BENCH_TRAIN_TIME:-150}"
train_dirs="Zend/tests ext/standard/tests/strings ext/standard/tests/array"
configure_opts="--disable-all --enable-cli --disable-cgi --disable-phpdbg --enable-opcache"
embed=0
case "${BENCH_EMBED:-0}" in 1|yes|true) embed=1 ;; esac
if [ "$embed" = 1 ]; then
    configure_opts="$configure_opts --enable-embed=shared"
    kinds="${BENCH_VARIANTS:-base gcc gcc-nsi}"
else
    kinds="${BENCH_VARIANTS:-base base-pgo llvm llvm-pgo llvm-pgo-lto gcc gcc-pgo}"
fi

res="$top/bench-results/$ver"
work="$top/bench-work/$ver"
logs="$res/logs"
rm -rf "$res" "$work"
mkdir -p "$res/variants" "$logs" "$work/bin" "$work/prof" "$work/scripts" || exit 1
info="$res/info.txt"
: > "$info"
: > "$res/runs.txt"
: > "$res/variants.txt"

if [ "$os" = FreeBSD ]; then
    ncpu="$(sysctl -n hw.ncpu)"
    cpu="$(sysctl -n hw.model)"
    mem="$(( $(sysctl -n hw.physmem) / 1048576 )) MB"
    hpinfo="superpages: vm.pmap.pg_ps_enabled=$(sysctl -n vm.pmap.pg_ps_enabled 2>/dev/null || echo '?')"
else
    ncpu="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)"
    cpu="$(sed -n 's/^model name[^:]*: *//p' /proc/cpuinfo 2>/dev/null | head -n 1)"
    mem="$(( $(sed -n 's/^MemTotal: *\([0-9]*\).*/\1/p' /proc/meminfo) / 1024 )) MB"
    hpinfo="transparent huge pages: $(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo '?'), hugetlb pages: $(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo '?')"
fi

# --- the compilers -----------------------------------------------------------------
# cc_major <cc>: the major version (clang -dumpversion: 19.1.7; gcc: 16 or 16.1.0)
cc_major() { "$1" -dumpversion 2>/dev/null | cut -d. -f1; }
is_clang() { "$1" --version 2>/dev/null | head -n 1 | grep -q clang; }
first_line() { "$@" 2>&1 | grep -v '^ *$' | head -n 1; }

# the packages of --deps, unless the prepare step of the workflow has installed them
if [ "$local" = 0 ] && [ ! -s "$top/bench-work/deps.txt" ]; then deps; fi
base_cc="${BENCH_BASE_CC:-}"
if [ -z "$base_cc" ]; then
    if [ -x /usr/bin/cc ] && is_clang /usr/bin/cc; then base_cc=/usr/bin/cc
    else base_cc="$(command -v clang 2>/dev/null)"; fi
fi
# the newest clang of the llvm packages: FreeBSD /usr/local/llvm<N>/bin/clang,
# Debian and Ubuntu /usr/lib/llvm-<N>/bin/clang
llvm_cc="${BENCH_LLVM_CC:-}"
if [ -z "$llvm_cc" ]; then
    llvm_cc="$(for c in /usr/local/llvm[0-9]*/bin/clang /usr/lib/llvm-[0-9]*/bin/clang; do
        [ -x "$c" ] && echo "$(echo "$c" | sed -E 's#.*/llvm-?([0-9]+)/bin/clang$#\1#') $c"
    done | sort -n | tail -n 1 | cut -d' ' -f2-)"
fi
# the newest GCC: FreeBSD /usr/local/bin/gcc<N>, Debian and Ubuntu /usr/bin/gcc-<N>, else gcc
gcc_cc="${BENCH_GCC:-}"
if [ -z "$gcc_cc" ]; then
    gcc_cc="$(for c in /usr/local/bin/gcc[0-9]* /usr/bin/gcc-[0-9]*; do
        case "${c##*/}" in gcc[0-9]|gcc[0-9][0-9]|gcc-[0-9]|gcc-[0-9][0-9]) ;; *) continue ;; esac
        [ -x "$c" ] && echo "$(echo "${c##*/}" | tr -dc 0-9) $c"
    done | sort -n | tail -n 1 | cut -d' ' -f2-)"
    [ -n "$gcc_cc" ] || gcc_cc="$(command -v gcc 2>/dev/null)"
    [ -n "$gcc_cc" ] && is_clang "$gcc_cc" && gcc_cc=""
fi
bm=""; lm=""; gm=""
[ -n "$base_cc" ] && is_clang "$base_cc" && bm="$(cc_major "$base_cc")"
[ -n "$llvm_cc" ] && is_clang "$llvm_cc" && lm="$(cc_major "$llvm_cc")"
[ -n "$gcc_cc" ] && gm="$(cc_major "$gcc_cc")"

# profdata_of <clang> <major>: its llvm-profdata, next to it (FreeBSD /usr/bin, which
# the base system builds with its default LLVM_COV, /usr/local/llvm<N>/bin; on Linux
# next to the real path of /usr/bin/clang), else that of an llvm package of the same
# version, or llvm-profdata-<major> or llvm-profdata of PATH when of the same version
profdata_of() {
    for d in "$(dirname "$1")" "$(dirname "$(realpath "$1" 2>/dev/null || echo "$1")")" \
            "/usr/local/llvm$2/bin" "/usr/lib/llvm-$2/bin"; do
        [ -x "$d/llvm-profdata" ] && { echo "$d/llvm-profdata"; return 0; }
    done
    for p in "llvm-profdata-$2" llvm-profdata; do
        p="$(command -v "$p" 2>/dev/null)" || continue
        "$p" --version 2>/dev/null | grep -q "version $2\." && { echo "$p"; return 0; }
    done
    return 1
}
base_pd=""; llvm_pd=""; llvm_lld=""
[ -n "$lm" ] && llvm_pd="$(profdata_of "$llvm_cc" "$lm")"
[ -n "$lm" ] && [ -x "$(dirname "$llvm_cc")/ld.lld" ] && llvm_lld="$(dirname "$llvm_cc")/ld.lld"
if [ -n "$bm" ]; then
    base_pd="$(profdata_of "$base_cc" "$bm")"
    if [ -z "$base_pd" ] && [ -n "$llvm_pd" ]; then
        base_pd="$llvm_pd"
        say "the base clang $bm has no llvm-profdata: clang$bm-pgo merges with that of clang$lm ($llvm_pd)"
    fi
fi

# --- the variants: "<kind> <name>" lines of bench-work/<version>/plan, in the order of the report
skip() { say "skip $1: $2"; printf '%s\tskipped: %s\n' "$1" "$2" >> "$res/variants.txt"; }
: > "$work/plan"
for k in base base-pgo base-nsi llvm llvm-pgo llvm-pgo-lto gcc gcc-pgo gcc-nsi; do
    case " $kinds " in *" $k "*) ;; *) continue ;; esac
    case "$k" in
        base*)
            n="clang$bm${k#base}"
            if [ -z "$bm" ]; then skip "$k" "no clang as the base cc (${base_cc:-none found})"; continue; fi
            # (only when variants of the llvm package run: they stand for these)
            case " $kinds " in *" llvm"*) llvm_asked=1 ;; *) llvm_asked=0 ;; esac
            if [ "$bm" = "$lm" ] && [ "$llvm_asked" = 1 ]; then skip "$n (base cc)" "the newest llvm is clang $lm too: its variants stand for these"; continue; fi
            if [ "$k" = base-pgo ] && [ -z "$base_pd" ]; then skip "$n" "no llvm-profdata for clang $bm"; continue; fi ;;
        llvm*)
            n="clang$lm${k#llvm}"
            if [ -z "$lm" ]; then skip "$k" "no clang of an llvm package (/usr/local/llvm<N>, /usr/lib/llvm-<N>)"; continue; fi
            case "$k" in *pgo*) [ -z "$llvm_pd" ] && { skip "$n" "no llvm-profdata of clang $lm"; continue; } ;; esac
            if [ "$k" = llvm-pgo-lto ] && [ -z "$llvm_lld" ]; then skip "$n" "no ld.lld next to $llvm_cc"; continue; fi ;;
        gcc*)
            n="gcc$gm${k#gcc}"
            if [ -z "$gm" ]; then skip "$k" "no GCC found"; continue; fi ;;
    esac
    echo "$k $n" >> "$work/plan"
done
names="$(cut -d' ' -f2 "$work/plan" | tr '\n' ' ' | sed 's/ *$//')"
baseline="$(head -n 1 "$work/plan" | cut -d' ' -f2)"
# through libphp: <name>-embed after each variant
[ "$embed" = 1 ] && names="$(for n in $names; do printf '%s %s-embed ' "$n" "$n"; done | sed 's/ *$//')"
[ -n "$baseline" ] || { echo "bench: no variant to build" >&2; exit 1; }
name_of() { awk -v k="$1" '$1 == k { print $2; exit }' "$work/plan"; }
in_plan() { grep -q "^$1 " "$work/plan"; }

# -march=x86-64-v3 as on the servers when this CPU runs it, else v2 (with a warning)
probe_cc="${base_cc:-${llvm_cc:-$gcc_cc}}"
cpu_feats() {
    "$probe_cc" "-march=$1" -dM -E - < /dev/null 2>/dev/null |
        sed -n -E 's/^#define __(SSE4_2|POPCNT|AVX|AVX2|BMI|BMI2|FMA|F16C|LZCNT|MOVBE)__ 1$/\1/p' | LC_ALL=C sort -u
}
cpu_feats x86-64-v3 > "$work/cpu-need"
cpu_feats native > "$work/cpu-have"
march=x86-64-v3
lacks="$(LC_ALL=C comm -23 "$work/cpu-need" "$work/cpu-have" | tr '\n' ' ' | sed 's/ *$//')"
if [ -n "$lacks" ]; then
    march=x86-64-v2
    say "WARNING: this CPU lacks $lacks of x86-64-v3: the variants are built for x86-64-v2"
fi
cflags="${BENCH_CFLAGS:--O3 -pipe -march=$march -fstack-protector-strong -fno-strict-aliasing -std=gnu17}"

# the runs on the last CPU (cpuset on FreeBSD, taskset on Linux)
pincpu=$((ncpu - 1))
pin=""
if command -v cpuset > /dev/null 2>&1 && cpuset -l "$pincpu" true 2>/dev/null; then pin="cpuset -l $pincpu"
elif command -v taskset > /dev/null 2>&1 && taskset -c "$pincpu" true > /dev/null 2>&1; then pin="taskset -c $pincpu"; fi

pd_version() { "$1" --version 2>&1 | grep -i 'version' | head -n 1 | sed 's/^ *//'; }
{
    echo "PHP $ver: $(basename "$tarball"), SHA-256 $(sha256_of "$tarball")"
    echo "system: $(uname -srm)"
    echo "CPU: $cpu; $ncpu CPUs, $mem; $hpinfo"
    if [ "$local" = 0 ]; then
        echo "packages: $(tr '\n' ' ' < "$top/bench-work/deps.txt" 2>/dev/null)from $(pkg -vv 2>/dev/null | sed -n 's/^ *url *: *"\([^"]*\)".*/\1/p' | head -n 1)"
    fi
    echo "configure: $configure_opts"
    echo "CFLAGS: $cflags"
    if in_plan base-nsi || in_plan gcc-nsi; then echo "CFLAGS of the -nsi variants: $cflags -fno-semantic-interposition"; fi
    if [ "$embed" = 1 ]; then echo "through libphp: each variant also as <name>-embed, the embed SAPI built shared, run by bench-embed.c (no php.ini)"; fi
    if in_plan base || in_plan base-pgo || in_plan base-nsi; then echo "compiler clang$bm (base): $base_cc: $(first_line "$base_cc" --version)"; fi
    if in_plan llvm || in_plan llvm-pgo || in_plan llvm-pgo-lto; then echo "compiler clang$lm: $llvm_cc: $(first_line "$llvm_cc" --version)"; fi
    if in_plan gcc || in_plan gcc-pgo || in_plan gcc-nsi; then echo "compiler gcc$gm: $gcc_cc: $(first_line "$gcc_cc" --version)"; fi
    in_plan base-pgo && echo "llvm-profdata of clang$bm-pgo: $base_pd: $(pd_version "$base_pd")"
    if in_plan llvm-pgo || in_plan llvm-pgo-lto; then echo "llvm-profdata of clang$lm-pgo: $llvm_pd: $(pd_version "$llvm_pd")"; fi
    in_plan llvm-pgo-lto && echo "linker of clang$lm-pgo-lto: $llvm_lld: $(first_line "$llvm_lld" --version)"
    echo "variants: $names (baseline $baseline)"
} > "$info"
cat "$info"
say "disk: $(df -h "$top" | tail -n 1)"

# --- building ----------------------------------------------------------------------
# first_errors <make.log>: the compiler and linker errors, else the last lines
first_errors() {
    grep -E ' error:|error: |Error [0-9]+|\*\*\* Error|undefined reference|undefined symbol|cannot find|Killed' "$1" |
        head -n 8 | grep . || tail -n 8 "$1"
}
# vinfo <name> <line>: a fact of a variant (the report lists them), paths from the top
vinfo() { echo "$2" | sed "s#$top/##g" >> "$res/variants/$1"; }
vfail() {
    say "FAIL $1: $2"
    printf '%s\tfailed: %s\n' "$1" "$2" >> "$res/variants.txt"
}
size_kb() { echo $(( $(wc -c < "$1") / 1024 )); }
comment_of() {
    readelf -p .comment "$1" 2>/dev/null | sed -n 's/^ *\[ *[0-9a-fA-F]*\] *//p' | sort -u | tr '\n' ';' | sed 's/;$//; s/;/; /g'
}
# make_php <src> <log> [<response file>]: make -j<cpus>, with PROF_FLAGS=@<file> when
# given; sets mk_time and, on a failure, mk_err (the errors are printed)
make_php() {
    t0=$(date +%s)
    if [ -n "${3:-}" ]; then (cd "$1" && make -j"$ncpu" PROF_FLAGS="@$3") > "$2" 2>&1
    else (cd "$1" && make -j"$ncpu") > "$2" 2>&1; fi
    mrc=$?
    mk_time=$(( $(date +%s) - t0 ))
    mk_err=""
    if [ $mrc -ne 0 ] || [ ! -x "$1/sapi/cli/php" ] || [ ! -f "$1/modules/opcache.so" ] ||
            { [ "$embed" = 1 ] && [ -z "$(ls "$1"/libs/libphp*.so 2>/dev/null)" ]; }; then
        mk_err="make: exit $mrc: $(first_errors "$2" | head -n 1 | sed "s#$1/##g" | cut -c1-300)"
        first_errors "$2" | sed "s#$1/##g; s/^/    /" | cut -c1-300
        return 1
    fi
    return 0
}
prof_clean() { (cd "$1" && make prof-clean) > /dev/null 2>&1; }
# save <name> <src>: the binaries of a variant into bench-work, its facts
save() {
    b="$work/bin/$1"
    rm -rf "$b"; mkdir -p "$b"
    if ! cp "$2/sapi/cli/php" "$b/php" || ! cp "$2/modules/opcache.so" "$b/opcache.so"; then
        vfail "$1" "copy of the binaries failed"; return 1
    fi
    if ! "$b/php" -n -v > "$work/v.txt" 2>&1; then vfail "$1" "php -n -v: $(head -n 1 "$work/v.txt")"; return 1; fi
    vinfo "$1" "php -v: $(head -n 1 "$work/v.txt")"
    vinfo "$1" "size: php $(size_kb "$b/php") KB, opcache.so $(size_kb "$b/opcache.so") KB; .comment: $(comment_of "$b/php")"
    printf '%s\tok\n' "$1" >> "$res/variants.txt"
    say "$1: built, php $(size_kb "$b/php") KB"
    [ "$embed" = 1 ] && save_embed "$1" "$2"
    return 0
}
# save_embed <name> <src>: the libphp of the tree next to the CLI, and the driver of the
# embed SAPI built against it (the base cc: the driver only starts PHP), as the variant
# <name>-embed; the proof that the driver loads that libphp (ldd) and that it runs
save_embed() {
    e="$1-embed"; b="$work/bin/$1"
    lib="$(ls "$2"/libs/libphp*.so 2>/dev/null | head -n 1)"
    [ -n "$lib" ] || { vfail "$e" "no libs/libphp*.so in the tree"; return 1; }
    cp "$lib" "$b/" || { vfail "$e" "copy of $lib failed"; return 1; }
    lib="$b/${lib##*/}"
    if ! "${base_cc:-cc}" -O2 -I"$2" -I"$2/main" -I"$2/Zend" -I"$2/TSRM" -I"$2/sapi/embed" -o "$b/embed" \
            "$work/scripts/bench-embed.c" "$lib" -Wl,-rpath,"$b" > "$work/embed-cc.txt" 2>&1; then
        vfail "$e" "the driver: $(grep -i -m 1 'error' "$work/embed-cc.txt" | cut -c1-300)"; return 1
    fi
    l="$(ldd "$b/embed" 2>/dev/null | awk -v n="${lib##*/}" '$1 == n && $2 == "=>" { print $3; exit }')"
    case "$(realpath "$l" 2>/dev/null)" in
        "$(realpath "$lib")") ;;
        *) vfail "$e" "the driver loads ${l:-no ${lib##*/}}, not $lib"; return 1 ;;
    esac
    printf '%s\n' '<?php echo PHP_VERSION, " ", PHP_SAPI, "\n";' > "$work/scripts/v.php"
    o="$("$b/embed" "$work/scripts/v.php" 2>&1)"
    case "$o" in
        *" embed") ;;
        *) vfail "$e" "the driver: $(echo "$o" | grep -v '^ *$' | head -n 1 | cut -c1-200)"; return 1 ;;
    esac
    vinfo "$e" "libphp: ${lib##*/}, $(size_kb "$lib") KB, $(readelf -r "$lib" 2>/dev/null | grep -c JUMP_SLO) PLT slots (JUMP_SLOT relocations); .comment: $(comment_of "$lib")"
    vinfo "$e" "loaded by the driver (ldd): $l; PHP_VERSION, PHP_SAPI: $o"
    printf '%s\tok\n' "$e" >> "$res/variants.txt"
    say "$e: built, ${lib##*/} $(size_kb "$lib") KB"
}

# train <src> <log prefix> <name> <LLVM_PROFILE_FILE>: the training run (see above),
# its counts into the facts of <name>
train() {
    ts="$1"; tlp="$2"; tn="$3"; tprof="$4"
    tphp="$ts/sapi/cli/php"
    tj=""
    "$tphp" -n "$ts/run-tests.php" --help 2>/dev/null | grep -q -- '-j<workers>' && tj="-j$ncpu"
    for part in nocache opcache; do
        set --
        if [ "$part" = opcache ]; then
            set -- -d "zend_extension=$ts/modules/opcache.so" -d opcache.enable_cli=1
            [ "$major" -ge 8 ] && set -- "$@" -d opcache.jit=tracing -d opcache.jit_buffer_size=128M
        fi
        tl="$tlp-$part.log"
        say "$tn: training, $part: run-tests.php -n -q $tj $* $train_dirs, at most ${train_time}s"
        t0=$(date +%s)
        # shellcheck disable=SC2086
        (cd "$ts" && exec env NO_INTERACTION=1 REPORT_EXIT_STATUS=0 SKIP_SLOW_TESTS=1 SKIP_ONLINE_TESTS=1 \
            TEST_PHP_EXECUTABLE="$tphp" LLVM_PROFILE_FILE="$tprof" \
            timeout --foreground -s TERM "$train_time" "$tphp" -n run-tests.php -n -q $tj "$@" $train_dirs) \
            > "$tl" 2>&1 < /dev/null
        trc=$?
        # run-tests.php stopped at the time limit: its workers and the tests that run end by themselves
        w=0
        while pgrep -f "$tphp" > /dev/null 2>&1 && [ $w -lt 120 ]; do sleep 1; w=$((w + 1)); done
        if pgrep -f "$tphp" > /dev/null 2>&1; then
            say "$tn: training, $part: tests still running 120s after the time limit, killed"
            pkill -KILL -f "$tphp" > /dev/null 2>&1
        fi
        dt=$(( $(date +%s) - t0 ))
        # one result per line: the colours and the progress lines (TEST n/m ... CR) away
        sed "s/$esc\[[0-9;]*m//g" "$tl" | tr '\r' '\n' > "$tl.lines"
        cnt="$(grep -c -E '^(PASS|FAIL|SKIP|XFAIL|XLEAK|BORK|LEAK|WARN)[ &]' "$tl.lines")"
        how="$(grep -c -E '^PASS ' "$tl.lines") passed, $(grep -c -E '^FAIL ' "$tl.lines") failed, $(grep -c -E '^SKIP ' "$tl.lines") skipped"
        if grep -q '^Tests passed' "$tl.lines"; then how="all of them in ${dt}s: $how"
        elif [ $trc -eq 124 ]; then how="stopped after ${train_time}s: $how"
        else how="run-tests.php ended with exit $trc after ${dt}s: $how; $(grep -v '^ *$' "$tl.lines" | tail -n 1 | cut -c1-200)"; fi
        rm -f "$tl.lines"
        vinfo "$tn" "training, $part: $cnt tests ($how)"
        say "$tn: training, $part: $cnt tests ($how)"
        [ "$cnt" -gt 0 ] || return 1
    done
    return 0
}

# profile <tree> <src> <family> <name>: the instrumented build, the training, the
# profile (clang: bench-work/<version>/prof/<tree>.profdata; gcc: the .gcda files of
# the tree); pf_err says why on a failure
profile() {
    pf_err=""
    rsp="$work/prof/$1-gen.rsp"
    pdir="$work/prof/$1-raw"
    rm -rf "$pdir"; mkdir -p "$pdir"
    # clang: more counters for the values of the indirect calls (the VM has many) than the
    # default 1 per site, else every process ends with "LLVM Profile Warning: Unable to
    # track new values: Running out of static counters" on stderr and fails its test
    if [ "$3" = clang ]; then echo "-fprofile-generate=$pdir -mllvm -vp-counters-per-site=8" > "$rsp"
    else echo "-fprofile-generate" > "$rsp"; fi
    prof_clean "$2"
    say "$4: the instrumented build (PROF_FLAGS: $(cat "$rsp"))"
    if ! make_php "$2" "$logs/$1/make-gen.log" "$rsp"; then pf_err="the instrumented build: $mk_err"; return 1; fi
    vinfo "$4" "instrumented build: ${mk_time}s, PROF_FLAGS: $(cat "$rsp")"
    find "$2" -name '*.gcda' -exec rm -f {} + 2>/dev/null
    if ! train "$2" "$logs/$1/train" "$4" "$pdir/php-%4m.profraw"; then
        pf_err="the training ran no test ($(basename "$logs/$1")/train-*.log)"; return 1
    fi
    if [ "$3" = clang ]; then
        pd="$base_pd"; [ "$1" = llvm ] && pd="$llvm_pd"
        ls "$pdir"/*.profraw > /dev/null 2>&1 || { pf_err="the training wrote no .profraw into $pdir"; return 1; }
        if ! "$pd" merge --failure-mode=all -o "$work/prof/$1.profdata" "$pdir"/*.profraw > "$logs/$1/merge.log" 2>&1; then
            pf_err="llvm-profdata merge: $(grep -v '^ *$' "$logs/$1/merge.log" | tail -n 1)"; return 1
        fi
        vinfo "$4" "profile: $(ls "$pdir"/*.profraw | wc -l | tr -d ' ') .profraw files ($(du -sk "$pdir" | cut -f1) KB) merged by $pd: $("$pd" show "$work/prof/$1.profdata" 2>/dev/null | grep -i 'total functions' | sed 's/^ *//')"
    else
        g="$(find "$2" -name '*.gcda' | wc -l | tr -d ' ')"
        [ "$g" -gt 0 ] || { pf_err="the training wrote no .gcda file"; return 1; }
        vinfo "$4" "profile: $g .gcda files"
    fi
    return 0
}

# use_build <tree> <src> <family> <name> <lto 0|1>: the build with the profile
use_build() {
    rsp="$work/prof/$1-use$5.rsp"
    if [ "$3" = clang ]; then echo "-fprofile-use=$work/prof/$1.profdata" > "$rsp"
    else echo "-fprofile-use -fprofile-correction" > "$rsp"; fi
    [ "$5" = 1 ] && echo "-flto=thin -fuse-ld=lld -O3" >> "$rsp"
    prof_clean "$2"
    say "$4: make -j$ncpu (PROF_FLAGS: $(tr '\n' ' ' < "$rsp"))"
    if ! make_php "$2" "$logs/$1/make-$4.log" "$rsp"; then vfail "$4" "$mk_err"; return 1; fi
    # the warnings about the profile of what php and opcache.so are made of: not those of
    # the PIC copies of the core objects in .libs/, which libtool builds and php does not link
    w="$(grep -E 'profile data may be|profile count data file not found|coverage mismatch|corrupted profile' "$logs/$1/make-$4.log" |
        awk '/profile count data file not found/ && /\/\.libs\// && !/ext\/opcache\// { next } { n++ } END { print n + 0 }')"
    vinfo "$4" "build: ${mk_time}s, PROF_FLAGS: $(tr '\n' ' ' < "$rsp" | sed 's/ *$//'); warnings about the profile: $w"
    save "$4" "$2"
}

# tree <tree> <cc> <family> <kind>...: one tree and one configure for the variants of a compiler
tree() {
    t="$1"; cc="$2"; fam="$3"; shift 3
    tw="$work/$t"
    rm -rf "$tw"; mkdir -p "$tw" "$logs/$t"
    if ! tar -xf "$tarball" -C "$tw"; then
        for k; do vfail "$(name_of "$k")" "unpack of $tarball failed"; done; return 1
    fi
    src="$(ls -d "$tw"/php-* | head -n 1)"
    [ -f "$work/scripts/bench.php" ] || cp "$src/Zend/bench.php" "$src/Zend/micro_bench.php" "$work/scripts/"
    tflags="$cflags"
    case "$t" in *-nsi) tflags="$cflags -fno-semantic-interposition" ;; esac
    ldflags=""
    # GCC of the ports: its runtime libraries by -rpath, as the ports link with USE_GCC
    if [ "$fam" = gcc ] && [ "$os" = FreeBSD ]; then
        gl="$("$cc" -print-file-name=libgcc_s.so)"
        case "$gl" in /*) ldflags="-Wl,-rpath=$(dirname "$gl")" ;; esac
    fi
    say "$t: configure with $cc"
    # shellcheck disable=SC2086
    if ! (cd "$src" && env CC="$cc" CFLAGS="$tflags" LDFLAGS="$ldflags" ./configure $configure_opts) > "$logs/$t/configure.log" 2>&1; then
        e="configure: $(grep -i 'error' "$logs/$t/configure.log" | tail -n 1 | cut -c1-300)"
        cp "$src/config.log" "$logs/$t/" 2>/dev/null
        for k; do vfail "$(name_of "$k")" "$e"; done
        rm -rf "$tw"; return 1
    fi
    cp "$src/config.log" "$logs/$t/"
    # the check of the global register variables, as config.log has it
    gr="$(awk '/checking for global register variables support/ { c = $0; f = 1 } f && /result:/ { print c " ... " $NF; exit }' "$src/config.log" |
        sed 's/^configure:[0-9]*: //')"
    [ -n "$gr" ] || gr="(no such check in config.log)"
    if [ "$fam" = gcc ] && ! echo "$gr" | grep -q 'yes$'; then say "WARNING: $t: GCC without global register variables: $gr"; fi
    for k; do
        n="$(name_of "$k")"
        vinfo "$n" "compiler: $cc ($(first_line "$cc" --version))"
        [ "$tflags" = "$cflags" ] || vinfo "$n" "CFLAGS: $tflags"
        [ -n "$ldflags" ] && vinfo "$n" "LDFLAGS: $ldflags"
        vinfo "$n" "config.log: $gr"
        say "$n: config.log: $gr"
        case "$k" in
            base|llvm|gcc|base-nsi|gcc-nsi)
                prof_clean "$src"
                say "$n: make -j$ncpu"
                if make_php "$src" "$logs/$t/make-$n.log"; then
                    vinfo "$n" "build: ${mk_time}s"
                    save "$n" "$src"
                else
                    vfail "$n" "$mk_err"
                fi ;;
            *)
                if [ ! -e "$work/prof/$t.done" ] && [ ! -e "$work/prof/$t.failed" ]; then
                    if profile "$t" "$src" "$fam" "$n"; then : > "$work/prof/$t.done"
                    else echo "$pf_err" > "$work/prof/$t.failed"; fi
                fi
                if [ -e "$work/prof/$t.failed" ]; then vfail "$n" "PGO: $(cat "$work/prof/$t.failed")"; continue; fi
                lto=0
                if [ "$k" = llvm-pgo-lto ]; then
                    lto=1
                    in_plan llvm-pgo && vinfo "$n" "profile: that of the training of clang$lm-pgo"
                fi
                use_build "$t" "$src" "$fam" "$n" "$lto" ;;
        esac
    done
    [ "${BENCH_KEEP:-0}" = 1 ] || rm -rf "$tw"
}
# kinds_in <kind>...: those of them in the plan
kinds_in() { for k; do in_plan "$k" && printf '%s ' "$k"; done; return 0; }
# the driver of the runs through libphp: the script of the command line through the
# embed SAPI, without php.ini (php -n)
if [ "$embed" = 1 ]; then
    cat > "$work/scripts/bench-embed.c" <<'EOF'
/* bench-embed.c of tools/bench.sh: run a script through the embed SAPI (libphp) */
#include <sapi/embed/php_embed.h>

int main(int argc, char **argv)
{
	volatile int ok = 0;

	if (argc < 2) {
		fprintf(stderr, "usage: %s <script.php>\n", argv[0]);
		return 2;
	}
	php_embed_module.php_ini_ignore = 1;
	PHP_EMBED_START_BLOCK(argc - 1, argv + 1)
		zend_file_handle fh;
		zend_stream_init_filename(&fh, argv[1]);
		ok = php_execute_script(&fh);
#if PHP_VERSION_ID >= 80100
		zend_destroy_file_handle(&fh);
#endif
	PHP_EMBED_END_BLOCK()
	return ok ? 0 : 1;
}
EOF
fi
# shellcheck disable=SC2046
[ -n "$(kinds_in base base-pgo)" ] && tree base "$base_cc" clang $(kinds_in base base-pgo)
in_plan base-nsi && tree base-nsi "$base_cc" clang base-nsi
# shellcheck disable=SC2046
[ -n "$(kinds_in llvm llvm-pgo llvm-pgo-lto)" ] && tree llvm "$llvm_cc" clang $(kinds_in llvm llvm-pgo llvm-pgo-lto)
# shellcheck disable=SC2046
[ -n "$(kinds_in gcc gcc-pgo)" ] && tree gcc "$gcc_cc" gcc $(kinds_in gcc gcc-pgo)
in_plan gcc-nsi && tree gcc-nsi "$gcc_cc" gcc gcc-nsi

# --- the benchmarks ----------------------------------------------------------------
ok="$(awk -F '\t' '$2 == "ok" { printf "%s ", $1 }' "$res/variants.txt" | sed 's/ *$//')"
modes="nocache opcache huge"
oc_args() {
    printf '%s\n' -d "zend_extension=$work/bin/$1/opcache.so" -d opcache.enable_cli=1
    [ "$major" -ge 8 ] && printf '%s\n' -d opcache.jit=tracing -d opcache.jit_buffer_size=128M
    return 0
}
# OPcache (and the JIT) must be on in mode opcache, or that mode of the variant is left out
: > "$work/no-opcache"
for v in $ok; do
    case "$v" in *-embed)
        vinfo "$v" "mode opcache: left out: OPcache does not run in the embed SAPI (not one of the SAPIs it supports)"
        echo "$v" >> "$work/no-opcache"; continue ;;
    esac
    # shellcheck disable=SC2046
    o="$("$work/bin/$v/php" -n $(oc_args "$v") -r '
        $s = function_exists("opcache_get_status") ? opcache_get_status(false) : false;
        if (!$s || empty($s["opcache_enabled"])) { echo "OPcache is not on"; exit(1); }
        echo "OPcache on";
        if (isset($s["jit"])) echo empty($s["jit"]["on"]) ? ", JIT off" : ", JIT on (opcache.jit=" . ini_get("opcache.jit") . ")";' 2>&1)"
    if [ $? -eq 0 ] && [ "$o" = "${o#*Warning}" ]; then
        vinfo "$v" "mode opcache: $o"
    else
        o="$(echo "$o" | grep -v '^ *$' | tr '\n' ' ' | cut -c1-300)"
        vinfo "$v" "mode opcache: left out: $o"
        say "FAIL $v: mode opcache left out: $o"
        echo "$v" >> "$work/no-opcache"
    fi
done
nv="$(echo $ok | wc -w | tr -d ' ')"
[ -n "$ok" ] && say "the benchmarks: $runs rounds of $ok${pin:+, pinned with $pin}, modes $modes"
r=1
while [ -n "$ok" ] && [ $r -le "$runs" ]; do
    say "round $r of $runs"
    order="$(echo $ok | tr ' ' '\n' | awk -v s=$(( (r - 1) % nv )) '{ a[NR] = $0 } END { for (i = 0; i < NR; i++) printf "%s ", a[(i + s) % NR + 1] }')"
    for sc in bench micro_bench; do
        for m in $modes; do
            for v in $order; do
                if [ "$m" = opcache ] && grep -qx "$v" "$work/no-opcache"; then continue; fi
                set -- -n
                # shellcheck disable=SC2046
                [ "$m" = opcache ] && set -- -n $(oc_args "$v")
                hp=0; [ "$m" = huge ] && hp=1
                case "$v" in
                    *-embed)
                        # shellcheck disable=SC2086
                        env USE_ZEND_ALLOC_HUGE_PAGES=$hp $pin timeout 900 "$work/bin/${v%-embed}/embed" "$work/scripts/$sc.php" > "$work/out.txt" 2>&1 ;;
                    *)
                        # shellcheck disable=SC2086
                        env USE_ZEND_ALLOC_HUGE_PAGES=$hp $pin timeout 900 "$work/bin/$v/php" "$@" "$work/scripts/$sc.php" > "$work/out.txt" 2>&1 ;;
                esac
                brc=$?
                tot="$(awk '$1 == "Total" { t = $2 } END { print t }' "$work/out.txt")"
                if [ $brc -ne 0 ] || [ -z "$tot" ]; then
                    say "FAIL $v $sc.php $m (round $r): exit $brc: $(grep -v '^ *$' "$work/out.txt" | tail -n 1 | cut -c1-200)"
                    echo "$v $sc $m $r fail" >> "$res/runs.txt"
                else
                    echo "$v $sc $m $r $tot" >> "$res/runs.txt"
                fi
            done
        done
    done
    r=$((r + 1))
done

# --- the report --------------------------------------------------------------------
jit=OPcache; [ "$major" -ge 8 ] && jit=OPcache+JIT
# table <txt|md>: the medians and their change against the baseline; the spread, the runs
table() {
    awk -v fmt="$1" -v order="$names" -v base="$baseline" -v runs="$runs" -v jit="$jit" '
        function isort(a, m,   i, j, t) { for (i = 2; i <= m; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]; a[j + 1] = t } }
        BEGIN {
            ns = split("bench micro_bench", S, " "); nm = split("nocache opcache huge", M, " ")
            L["nocache"] = "no OPcache"; L["opcache"] = jit; L["huge"] = "huge pages"
            nv = split(order, V, " ")
            if (fmt == "md") { fv = "| %s |"; fc = " %s |"; pc = " (%+.1f%%)" } else { fv = "%-18s"; fc = "%-20s"; pc = " %+.1f%%" }
        }
        { k = $1 SUBSEP $2 SUBSEP $3; raw[k] = raw[k] " " $5; if ($5 == "fail") bad[k]++; else { n[k]++; x[k, n[k]] = $5 } }
        END {
            for (k in n) {
                m = n[k]; for (i = 1; i <= m; i++) a[i] = x[k, i] + 0; isort(a, m)
                med[k] = (m % 2) ? a[(m + 1) / 2] : (a[m / 2] + a[m / 2 + 1]) / 2
                sp = med[k] > 0 ? (a[m] - a[1]) / med[k] * 100 : 0
                nsp++; spr[nsp] = sp; if (nsp == 1 || sp > spmax) { spmax = sp; spk = k }
            }
            if (fmt == "md") {
                printf "| variant |"; for (s = 1; s <= ns; s++) for (j = 1; j <= nm; j++) printf " %s.php<br>%s |", S[s], L[M[j]]
                printf "\n|---|"; for (s = 1; s <= ns * nm; s++) printf "--:|"; printf "\n"
            } else {
                printf "%-18s", "variant"; for (s = 1; s <= ns; s++) for (j = 1; j <= nm; j++) printf "%-20s", (j == 1 ? S[s] ".php" : "")
                printf "\n%-18s", ""; for (s = 1; s <= ns; s++) for (j = 1; j <= nm; j++) printf "%-20s", L[M[j]]
                printf "\n"
            }
            for (i = 1; i <= nv; i++) {
                printf fv, V[i]
                for (s = 1; s <= ns; s++) for (j = 1; j <= nm; j++) {
                    k = V[i] SUBSEP S[s] SUBSEP M[j]; b = base SUBSEP S[s] SUBSEP M[j]; c = "-"
                    if (k in med) {
                        c = sprintf("%.3f", med[k])
                        if (V[i] != base && (b in med) && med[b] > 0) c = c sprintf(pc, (med[k] - med[b]) / med[b] * 100)
                        if (n[k] < runs) c = c " [" n[k] "/" runs "]"
                    } else if (k in bad) c = "failed"
                    printf fc, c
                }
                printf "\n"
            }
            if (nsp && runs > 1) {
                isort(spr, nsp); split(spk, w, SUBSEP)
                printf "\nSpread of the runs of a cell, (max - min) / median: %.1f%% in the middle cell, %.1f%% at most (%s, %s.php, %s).\n", (nsp % 2) ? spr[(nsp + 1) / 2] : (spr[nsp / 2] + spr[nsp / 2 + 1]) / 2, spmax, w[1], w[2], L[w[3]]
            }
            printf "\nThe runs, seconds, in the order they ran:\n"
            for (i = 1; i <= nv; i++) for (s = 1; s <= ns; s++) for (j = 1; j <= nm; j++) {
                k = V[i] SUBSEP S[s] SUBSEP M[j]
                if (k in raw) printf "  %-18s %-16s %-12s%s\n", V[i], S[s] ".php", L[M[j]], raw[k]
            }
        }' "$res/runs.txt"
}
# embed_table <txt|md>: through libphp, for each variant: its -embed against its CLI and
# against the -embed of the baseline, the median of the ratios of the runs of one round
embed_table() {
    awk -v fmt="$1" -v order="$(cut -d' ' -f2 "$work/plan" | tr '\n' ' ')" -v base="$baseline" -v runs="$runs" '
        function isort(a, m,   i, j, t) { for (i = 2; i <= m; i++) { t = a[i]; for (j = i - 1; j >= 1 && a[j] > t; j--) a[j + 1] = a[j]; a[j + 1] = t } }
        function chg(va, vb, sc, m,   r, k, x, v) {
            k = 0
            for (r = 1; r <= runs; r++) if (((va, sc, m, r) in t) && ((vb, sc, m, r) in t) && t[vb, sc, m, r] > 0) x[++k] = t[va, sc, m, r] / t[vb, sc, m, r]
            if (!k) return "-"
            isort(x, k); v = (k % 2) ? x[(k + 1) / 2] : (x[k / 2] + x[k / 2 + 1]) / 2
            return sprintf("%+.1f%%", (v - 1) * 100) ((k < runs) ? " [" k "/" runs "]" : "")
        }
        $5 != "fail" { t[$1, $2, $3, $4] = $5 + 0 }
        END {
            ns = split("bench micro_bench", S, " "); nm = split("nocache huge", M, " ")
            L["nocache"] = "no OPcache"; L["huge"] = "huge pages"
            nv = split(order, V, " ")
            if (fmt == "md") {
                printf "| variant |"
                for (p = 1; p <= 2; p++) for (s = 1; s <= ns; s++) for (j = 1; j <= nm; j++)
                    printf " %s.php %s:<br>%s |", S[s], L[M[j]], (p == 1) ? "embed vs its CLI" : "vs " base "-embed"
                printf "\n|---|"; for (s = 1; s <= 2 * ns * nm; s++) printf "--:|"; printf "\n"
            } else {
                printf "%-14s", "variant"; for (p = 1; p <= 2; p++) { printf "%-56s", (p == 1) ? "<variant>-embed against the CLI of its build" : "<variant>-embed against " base "-embed" }
                printf "\n%-14s", ""; for (p = 1; p <= 2; p++) for (s = 1; s <= ns; s++) for (j = 1; j <= nm; j++) printf "%-14s", (s == 1 ? "bench" : "micro") " " (j == 1 ? "nocache" : "huge")
                printf "\n"
            }
            fv = (fmt == "md") ? "| %s |" : "%-14s"; fc = (fmt == "md") ? " %s |" : "%-14s"
            for (i = 1; i <= nv; i++) {
                printf fv, V[i]
                for (p = 1; p <= 2; p++) for (s = 1; s <= ns; s++) for (j = 1; j <= nm; j++) {
                    c = (p == 1) ? chg(V[i] "-embed", V[i], S[s], M[j]) : (V[i] == base) ? "-" : chg(V[i] "-embed", base "-embed", S[s], M[j])
                    printf fc, c
                }
                printf "\n"
            }
        }' "$res/runs.txt"
}
rw=runs; [ "$runs" = 1 ] && rw=run
opc="-d zend_extension=opcache.so -d opcache.enable_cli=1"
[ "$major" -ge 8 ] && opc="$opc -d opcache.jit=tracing -d opcache.jit_buffer_size=128M"
{
    echo "=== PHP $ver: the speed of the builds (tools/bench.sh)"
    cat "$info"
    echo "training of the PGO variants: run-tests.php -n -q -j$ncpu of the same tree on $train_dirs (SKIP_SLOW_TESTS, SKIP_ONLINE_TESTS), without OPcache, then with $jit; each part stopped after ${train_time}s"
    echo "runs: $runs of each script for each variant and mode, the variants interleaved${pin:+, pinned to CPU $pincpu ($pin)}"
    echo "modes: no OPcache (php -n), $jit ($opc), huge pages (no OPcache, USE_ZEND_ALLOC_HUGE_PAGES=1)"
    echo
    echo "variants:"
    for v in $names; do
        st="$(awk -F '\t' -v v="$v" '$1 == v { s = $2 } END { print s }' "$res/variants.txt")"
        echo "  $v: ${st:-not built}"
        [ -f "$res/variants/$v" ] && sed 's/^/      /' "$res/variants/$v"
    done
    awk -F '\t' '$2 ~ /^skipped/ { print "  " $1 ": " $2 }' "$res/variants.txt"
    echo
    echo "The median of the \"Total\" line of $runs $rw in seconds; after it the change against $baseline (negative: faster); [n/$runs] when runs failed:"
    echo
    table txt
    if [ "$embed" = 1 ]; then
        echo
        echo "Through libphp (the embed SAPI built shared): the median of the ratios of the runs of one round, in % (negative: faster):"
        echo
        embed_table txt
    fi
} > "$res/report.txt"
{
    echo "### PHP $ver: the speed of the builds"
    echo
    sed 's/^/- /' "$info"
    echo
    echo "The median of the \"Total\" line of $runs $rw in seconds, and the change against \`$baseline\` (negative: faster); [n/$runs] when runs failed."
    echo
    table md | sed '/^$/,$d'
    if [ "$embed" = 1 ]; then
        echo
        echo "Through libphp (the embed SAPI built shared, \`<variant>-embed\`): the median of the ratios of the runs of one round (negative: faster)."
        echo
        embed_table md
    fi
    echo
    echo '<details><summary>the variants, the training, every run</summary>'
    echo
    echo '```text'
    sed -n '/^training of the PGO/,/^variants:$/p' "$res/report.txt" | sed '$d'
    sed -n '/^variants:$/,/^The median of/p' "$res/report.txt" | sed '$d'
    table txt | sed -n -E '/^(Spread|The runs)/,$p'
    echo '```'
    echo
    echo '</details>'
} > "$res/report.md"
echo
cat "$res/report.txt"
[ "${BENCH_KEEP:-0}" = 1 ] || rm -rf "$work"
[ -n "$ok" ] && [ -s "$res/runs.txt" ] || exit 1
exit 0
