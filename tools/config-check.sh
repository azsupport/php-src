#!/bin/sh
# config-check.sh - before reusing a config.nice for a rebuild, compare its
# ./configure options with those of the PHP build that is actually installed.
# The installed build wins: a config script with the installed build's options,
# config.installed.sh, is always written to the current directory; run that one.
#
# Usage (FreeBSD /bin/sh; from csh run it with sh):
#   sh config-check.sh /usr/local/php81
#   sh config-check.sh /usr/local/php81 /root/php-8.1.34/config.nice
#   sh config-check.sh --pkg [php74]
#
#   The first argument is the install directory of the hand-built PHP (its bin/php,
#   or else sbin/php-fpm or bin/php-cgi is used), or one of those binaries.
#   --pkg instead writes the options for a hand build that replaces the PHP
#   installed as packages (lang/phpXY, phpXY-* extensions, mod_phpXY): the port
#   options of phpXY, one option per extension package, the layout of our hand
#   builds (/usr/local/phpXY) and CFLAGS from /etc/make.conf (CFLAGS, CPUTYPE).
#   The second argument is the config.nice of the old build. Without it,
#   ./config.nice is used, or else the newest php-<version>/config.nice or
#   php-<version>-*/config.nice next to the current directory or in $HOME, where
#   <version> is the installed version (php-8.1.34, php-8.1.34-fbsd-20261021-...).
#   Run it from inside the new PHP source tree, then: sh config.installed.sh
#   OUT=/path/file.sh overrides where the script goes (default: ./config.installed.sh).
#
# The installed options come from "<binary> -n -i" (Configure Command; -n skips
# php.ini, so a broken shared extension does not get in the way) or, failing that,
# from php-config --configure-options next to the binary. Environment lines of
# config.nice (CFLAGS=... and the like) are shown and carried over, but not
# compared: the installed build does not record them. PHP 5.6 records options with
# spaces in a broken quoting ('CFLAGS=-O3 '-pipe' '-march=...''); both sources are
# split the way the shell would, so such an option stays one option.
#
# Exit status: 0 same options, 1 different (or no config.nice to compare with),
# 2 usage or read error.

set -u
out="${OUT:-./config.installed.sh}"

# --pkg: the ./configure options for a hand build that replaces the PHP installed
# as FreeBSD packages (lang/phpXY, its phpXY-* extension packages, mod_phpXY), in
# the layout of our hand builds, with CFLAGS from /etc/make.conf.
if [ "${1:-}" = "--pkg" ]; then
    [ $# -le 2 ] || { sed -n 's/^# \{0,1\}//; 7,10p' "$0" >&2; exit 2; }
    pkg="${PKG:-pkg}"
    mk_conf="${MAKE_CONF:-/etc/make.conf}"
    lb="${LOCALBASE:-/usr/local}"
    tmp="$(mktemp -d)" || exit 2
    trap 'rm -rf "$tmp"' EXIT INT TERM

    want="${2:-}"
    case "$want" in
        "" | php[0-9][0-9]) ;;
        [0-9].[0-9]) want="php$(printf '%s' "$want" | tr -d .)" ;;
        [0-9][0-9]) want="php$want" ;;
        *) echo "config-check: --pkg takes a package name (php74), a version (7.4) or 74" >&2; exit 2 ;;
    esac
    cores="$("$pkg" query -g '%n' 'php[0-9][0-9]' 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
    if [ -z "$want" ]; then
        case "$cores" in
            "") echo "config-check: no PHP package (lang/phpXY) is installed" >&2; exit 2 ;;
            *" "*) echo "config-check: several PHP packages are installed ($cores); name one: sh config-check.sh --pkg php74" >&2; exit 2 ;;
        esac
        want="$cores"
    fi
    pkgver="$("$pkg" query '%v' "$want" 2>/dev/null)"
    [ -n "$pkgver" ] || { echo "config-check: $want is not installed (PHP packages: ${cores:-none})" >&2; exit 2; }
    short="${want#php}"
    minor="${short#?}"
    case "$short" in
        5*) fam=5 ;;
        7*) fam=7 ;;
        *) fam=8 ;;
    esac
    prefix="/usr/local/php$short"

    : > "$tmp/opts"; : > "$tmp/map"; : > "$tmp/skip"; : > "$tmp/notes"
    add() { for o in "$@"; do grep -qxF -- "$o" "$tmp/opts" || printf '%s\n' "$o" >> "$tmp/opts"; done; }
    note() { printf '%s\n' "$*" >> "$tmp/notes"; }
    has() { [ -f "$lb/include/$1" ]; }
    "$pkg" query '%Ok %Ov' "$want" > "$tmp/core" 2>/dev/null
    opt() { grep -qx "$1 $2" "$tmp/core"; }
    "$pkg" query '%dn' "$want" > "$tmp/deps" 2>/dev/null
    modphp="$("$pkg" query -g '%n' "mod_php$short" 2>/dev/null)"
    intl=""

    # Configure options of one extension package, in the style of our hand builds
    # (the FreeBSD port's Makefile.ext passes the same, mostly with LOCALBASE paths).
    # Exit 1 with the reason on stdout for a package that has no option.
    ext_flags() {
        case "$1" in
            bcmath|calendar|ctype|dba|dom|exif|fileinfo|filter|ftp|mbstring|pcntl|pdo|phar|posix|\
session|shmop|simplexml|soap|sockets|sysvmsg|sysvsem|sysvshm|tokenizer|xml|xmlreader|xmlwriter)
                echo "--enable-$1" ;;
            json) [ "$fam" = 8 ] || echo "--enable-json" ;;
            opcache) if [ "$fam" = 8 ]; then echo "--enable-opcache --enable-opcache-jit"; else echo "--enable-opcache"; fi ;;
            intl) if [ "$fam" = 5 ]; then echo "--enable-intl --with-icu-dir=/usr/local"; else echo "--enable-intl"; fi ;;
            bz2) echo "--with-bz2" ;;
            curl) if [ "$fam" = 5 ]; then echo "--with-curl"; else echo "--with-curl=/usr/local"; fi ;;
            enchant) echo "--with-enchant=/usr/local" ;;
            ffi) echo "--with-ffi" ;;
            gd)
                if [ "$fam" = 5 ]; then
                    f="--with-gd"
                    has jpeglib.h && f="$f --with-jpeg-dir=/usr/local"
                    has png.h && f="$f --with-png-dir=/usr/local"
                    has freetype2/ft2build.h && f="$f --with-freetype-dir=/usr/local"
                    echo "$f"
                else
                    has gd.h || note "--with-external-gd needs the libgd package ($lb/include/gd.h is missing)."
                    echo "--enable-gd --with-external-gd"
                fi ;;
            gettext) if [ "$fam" = 5 ]; then echo "--with-gettext"; else echo "--with-gettext=/usr/local"; fi ;;
            gmp) echo "--with-gmp=/usr/local" ;;
            iconv) echo "--with-iconv=/usr/local" ;;
            imap) if [ "$fam" = 8 ] && [ "$minor" -ge 4 ]; then echo "removed from PHP in 8.4 (PECL imap)"; return 1; fi
                  echo "--with-imap=/usr/local --with-imap-ssl=/usr" ;;
            ldap) echo "--with-ldap=/usr/local" ;;
            mcrypt) if [ "$fam" = 5 ]; then echo "--with-mcrypt=/usr/local"; else echo "removed from PHP in 7.2 (PECL mcrypt)"; return 1; fi ;;
            mysql) if [ "$fam" = 5 ]; then echo "--with-mysql --with-mysql-sock=/tmp/mysql.sock"; else echo "removed from PHP in 7.0 (use mysqli or pdo_mysql)"; return 1; fi ;;
            mysqli) if [ "$fam" = 5 ]; then echo "--with-mysqli --with-mysql-sock=/tmp/mysql.sock"; else echo "--with-mysqli=mysqlnd --with-mysql-sock=/tmp/mysql.sock"; fi ;;
            odbc) echo "--with-unixODBC=/usr/local" ;;
            openssl) case "$fam" in 5) echo "--with-openssl=/usr" ;; 7) echo "--with-openssl" ;; *) echo "--with-openssl=/usr" ;; esac ;;
            pdo_dblib) echo "--with-pdo-dblib=/usr/local" ;;
            pdo_firebird) echo "--with-pdo-firebird=/usr/local" ;;
            pdo_mysql) if [ "$fam" = 5 ]; then echo "--with-pdo-mysql --with-mysql-sock=/tmp/mysql.sock"; else echo "--with-pdo-mysql=mysqlnd --with-mysql-sock=/tmp/mysql.sock"; fi ;;
            pdo_odbc) echo "--with-pdo-odbc=unixODBC,/usr/local" ;;
            pdo_pgsql) echo "--with-pdo-pgsql=/usr/local" ;;
            pdo_sqlite) if [ "$fam" = 5 ]; then echo "--with-pdo-sqlite=/usr/local"; else echo "--with-pdo-sqlite"; fi ;;
            pgsql) echo "--with-pgsql=/usr/local" ;;
            pspell) if [ "$fam" = 8 ] && [ "$minor" -ge 4 ]; then echo "removed from PHP in 8.4 (PECL pspell)"; return 1; fi
                    echo "--with-pspell=/usr/local" ;;
            readline) if has readline/readline.h; then echo "--with-readline=/usr/local"; else echo "--with-libedit"; fi ;;
            snmp) echo "--with-snmp=/usr/local" ;;
            sodium) echo "--with-sodium=/usr/local" ;;
            sqlite3) if [ "$fam" = 5 ]; then echo "--with-sqlite3=/usr/local"; else echo "--with-sqlite3"; fi ;;
            tidy) echo "--with-tidy=/usr/local" ;;
            wddx) if [ "$fam" = 5 ]; then echo "--enable-wddx"; else echo "removed from PHP in 7.4"; return 1; fi ;;
            xmlrpc) if [ "$fam" = 8 ]; then echo "removed from PHP in 8.0 (PECL xmlrpc)"; return 1; fi; echo "--with-xmlrpc" ;;
            xsl) if [ "$fam" = 5 ]; then echo "--with-xsl=/usr/local"; else echo "--with-xsl"; fi ;;
            zip) if [ "$fam" = 5 ]; then echo "--enable-zip"; else echo "--with-zip"; fi ;;
            zlib) if [ "$fam" = 5 ]; then echo "--with-zlib=/usr"; else echo "--with-zlib"; fi ;;
            pecl-redis) echo "--enable-redis" ;;
            pecl-memcached) echo "--enable-memcached --with-libmemcached-dir=/usr/local --disable-memcached-sasl" ;;
            pecl-memcache) echo "--enable-memcache" ;;
            pecl-imagick) echo "--with-imagick=/usr/local" ;;
            pecl-*) echo "PECL extension, not part of ./configure: build it later with $prefix/bin/phpize"; return 1 ;;
            *) echo "not an extension of the PHP sources (a tool, or one this script does not know)"; return 1 ;;
        esac
    }

    # The core package: layout of our hand builds, then its port options.
    [ -n "$modphp" ] && add --with-apxs2=/usr/local/sbin/apxs
    if [ "$fam" = 5 ]; then
        add --prefix="$prefix" --disable-all --with-layout=GNU --with-zend-vm=CALL --enable-libxml \
            --with-libxml-dir=/usr/local --with-regex=php --enable-mysqlnd
    else
        add --with-layout=GNU --localstatedir=/var --disable-all --with-libxml --program-prefix= \
            --prefix="$prefix" --mandir="$prefix/man" --infodir="$prefix/info/"
    fi
    opt CLI off && add --disable-cli
    opt CGI off && add --disable-cgi
    opt FPM on && add --enable-fpm --with-fpm-user=www --with-fpm-group=www
    opt EMBED on && add --enable-embed
    opt PHPDBG on && add --enable-phpdbg
    opt IPV6 off && add --disable-ipv6
    if opt ZTS on; then
        if [ "$fam" = 8 ]; then add --enable-zts; else add --enable-maintainer-zts; fi
    fi
    opt MYSQLND on && add --enable-mysqlnd
    libs=""
    opt LINKTHR on && libs="-lpthread"
    opt DEBUG on && note "DEBUG is on in the package: not carried over (add --enable-debug for a debug build)."
    opt DTRACE on && note "DTRACE is on in the package: not carried over (add --enable-dtrace to keep the DTrace probes)."
    opt MAILHEAD on && note "MAILHEAD (the mail() header patch of the php56 port) is not in this fork."
    if [ "$fam" = 5 ]; then
        if has pcre.h; then add --with-pcre-regex=/usr/local
        else note "No $lb/include/pcre.h (package pcre): the old bundled PCRE 8.38 is used."; fi
    elif ! opt PCRE off; then
        if has pcre2.h; then add --with-external-pcre=/usr/local
        else note "No $lb/include/pcre2.h (package pcre2): the bundled PCRE2 is used."; fi
    fi
    if [ "$fam" = 8 ]; then
        add --with-openssl=/usr
    fi
    if [ "$fam" != 5 ]; then
        if grep -qx libargon2 "$tmp/deps"; then add --with-password-argon2=/usr/local
        elif [ "$fam" = 8 ] && [ "$minor" -ge 4 ]; then add --with-openssl-argon2; fi
    fi

    # The extension packages.
    "$pkg" query -g '%n' "php$short-*" 2>/dev/null | sort > "$tmp/ext_pkgs"
    n_ext=0
    while IFS= read -r p; do
        e="${p#php"$short"-}"
        [ "$e" = extensions ] && continue
        if f="$(ext_flags "$e")"; then
            [ "$e" = intl ] && intl=1
            # shellcheck disable=SC2086
            [ -n "$f" ] && add $f
            printf '  %-24s %s\n' "$p" "${f:-(built into PHP $fam, no option)}" >> "$tmp/map"
            n_ext=$((n_ext + 1))
        else
            printf '  %-24s %s\n' "$p" "$f" >> "$tmp/skip"
        fi
    done < "$tmp/ext_pkgs"

    # CFLAGS: those of /etc/make.conf plus -march=$CPUTYPE, as for the ports.
    mc_get() {
        [ -r "$mk_conf" ] || return 0
        awk -v v="$1" '
            { sub(/#.*/, "") }
            $0 ~ "^[ \t]*" v "[ \t]*[?:]?=" { s = $0; sub("^[ \t]*" v "[ \t]*[?:]?=[ \t]*", "", s); val = s; have = 1; next }
            $0 ~ "^[ \t]*" v "[ \t]*\\+=" { s = $0; sub("^[ \t]*" v "[ \t]*\\+=[ \t]*", "", s); val = val " " s; have = 1 }
            END { if (have) { sub(/[ \t]+$/, "", val); print val } }
        ' "$mk_conf"
    }
    mc_cflags="$(mc_get CFLAGS)"
    cputype="$(mc_get CPUTYPE)"
    cflags="${mc_cflags:--O2 -pipe}${cputype:+ -march=$cputype} -fstack-protector-strong -fno-strict-aliasing"
    cxxflags="$cflags"
    [ -n "$intl" ] && [ "$fam" != 5 ] && cxxflags="-std=c++17 $cflags"

    out_dir="$(cd "$(dirname "$out")" 2>/dev/null && pwd)" || { echo "config-check: no directory for $out" >&2; exit 2; }
    out="$out_dir/$(basename "$out")"
    {
        echo "#!/bin/sh"
        echo "# Written by config-check.sh --pkg on $(date '+%d.%m.%Y %H:%M'): a hand build that replaces"
        echo "# the packages $want $pkgver${modphp:+, $modphp} and $n_ext extension packages; CFLAGS from $mk_conf."
        echo "# Run from inside the new PHP source tree: sh $out"
        echo
        printf "CFLAGS='%s' \\\\\n" "$cflags"
        printf "CXXFLAGS='%s' \\\\\n" "$cxxflags"
        [ -n "$libs" ] && printf "LIBS='%s' \\\\\n" "$libs"
        echo "'./configure' \\"
        sed "s/'/'\\\\''/g; s/^/'/; s/\$/' \\\\/" "$tmp/opts"
        echo '"$@"'
    } > "$out" || { echo "config-check: cannot write $out" >&2; exit 2; }
    chmod +x "$out" 2>/dev/null || true

    # Report.
    printf 'packages:   %s %s%s, %s extension packages\n' "$want" "$pkgver" "${modphp:+, $modphp}" "$n_ext"
    printf 'port opts:  %s\n' "$(tr '\n' ',' < "$tmp/core" | sed 's/,$//; s/,/, /g')"
    printf 'make.conf:  CPUTYPE=%s, CFLAGS=%s (%s)\n' "${cputype:-unset}" "${mc_cflags:-unset}" "$mk_conf"
    echo
    echo "extension packages and their options:"
    cat "$tmp/map"
    if [ -s "$tmp/skip" ]; then
        echo
        echo "not carried over:"
        cat "$tmp/skip"
    fi
    echo
    echo "notes:"
    sed 's/^/  - /' "$tmp/notes"
    echo "  - php.ini: the packages read /usr/local/etc/php.ini and /usr/local/etc/php/*.ini; the new build"
    echo "    reads $prefix/etc/php.ini. The extensions are compiled in, the ext-*.ini files are not needed."
    if [ -n "$modphp" ]; then
        echo "  - make install puts the Apache module where $modphp has it: run pkg delete $modphp first,"
        echo "    or the next pkg upgrade writes the package's module over it."
    fi
    opt FPM on && echo "  - php-fpm goes to $prefix/sbin/php-fpm; the package's rc.d script starts /usr/local/sbin/php-fpm."
    set -- "$want"
    [ -n "$modphp" ] && set -- "$@" "$modphp"
    while IFS= read -r p; do set -- "$@" "$p"; done < "$tmp/ext_pkgs"
    "$pkg" query '%dn' "$@" 2>/dev/null | grep -v -e '^php' -e '^mod_php' | sort -u > "$tmp/libs"
    if [ -s "$tmp/libs" ]; then
        echo "  - Before deleting the PHP packages, keep the libraries the new build links against, so that"
        echo "    pkg autoremove does not remove them:"
        echo
        echo "pkg set -y -A 0 $(tr '\n' ' ' < "$tmp/libs" | sed 's/ *$//')"
    fi
    echo
    echo "written: $out"
    echo "next, from inside the new source tree: sh $out"
    exit 0
fi

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    sed -n 's/^# \{0,1\}//; 7,10p' "$0" >&2
    exit 2
fi
target="$1"
nice="${2:-}"

if [ -d "$target" ]; then
    php=""
    for c in bin/php sbin/php-fpm bin/php-cgi; do
        if [ -x "$target/$c" ]; then php="$target/$c"; break; fi
    done
    [ -n "$php" ] || { echo "config-check: no bin/php, sbin/php-fpm or bin/php-cgi in $target" >&2; exit 2; }
else
    php="$target"
fi
[ -x "$php" ] || { echo "config-check: $php is not an executable file" >&2; exit 2; }

tmp="$(mktemp -d)" || exit 2
trap 'rm -rf "$tmp"' EXIT INT TERM

# One option per line, split like the shell splits words (quotes removed, adjacent
# quoted parts joined; xargs only parses, it runs nothing but printf). Falls back
# to taking every '...' group if xargs rejects the quoting. The ./configure path
# itself is dropped.
to_lines() {
    if ! printf '%s\n' "$1" | xargs -n 1 printf '%s\n' > "$tmp/split" 2>/dev/null; then
        echo "config-check: warning: unbalanced quotes in the options from ${2:-?}" \
             "(a PHP 5.6 value that ends in a space?); options with spaces may come out split" >&2
        case "$1" in
            *\'*) printf '%s\n' "$1" | grep -o "'[^']*'" | sed "s/^'//; s/'\$//" ;;
            *) printf '%s\n' "$1" | tr -s '[:blank:]' '\n' ;;
        esac > "$tmp/split"
    fi
    grep -v -e '^$' -e '^[^-].*configure$' "$tmp/split"
}

# Installed build.
line="$("$php" -n -i 2>/dev/null | sed -n 's/^Configure Command =>[[:space:]]*//p' | head -1)"
how="$php -n -i"
if [ -z "$line" ]; then
    pc="$(dirname "$php")/php-config"
    if [ -x "$pc" ]; then
        line="$("$pc" --configure-options 2>/dev/null)"
        how="$pc --configure-options"
    fi
fi
[ -n "$line" ] || { echo "config-check: no configure options from $php (php -i failed, no php-config)" >&2; exit 2; }
to_lines "$line" "$how" > "$tmp/installed_order"
LC_ALL=C sort -u "$tmp/installed_order" > "$tmp/installed"
version="$("$php" -n -v 2>/dev/null | head -1)"
ver="$(printf '%s\n' "$version" | awk '{print $2}')"

# The old build's config.nice: given, ./config.nice, or found next to this tree.
found=""
if [ -z "$nice" ]; then
    if [ -r ./config.nice ]; then
        nice=./config.nice
    elif [ -n "$ver" ]; then
        here="$(pwd)"
        for d in .. "${HOME:-/root}"; do
            [ -d "$d" ] || continue
            for f in "$d/php-$ver/config.nice" "$d/php-$ver"-*/config.nice; do
                [ -r "$f" ] || continue
                [ "$(cd "$(dirname "$f")" && pwd)" = "$here" ] && continue
                printf '%s\n' "$f"
            done
        done > "$tmp/candidates"
        if [ -s "$tmp/candidates" ]; then
            # newest first; the list has no spaces in practice (php-<version>* names)
            # shellcheck disable=SC2046
            nice="$(ls -t $(cat "$tmp/candidates") | head -1)"
            found=" (newest config.nice of PHP $ver found here; give another one as the second argument)"
        fi
    fi
fi
if [ -n "$nice" ] && [ ! -r "$nice" ]; then
    echo "config-check: cannot read $nice" >&2
    exit 2
fi

# config.nice: NAME='value' lines before the configure line are environment
# settings; everything from the configure line on (continuation lines joined)
# holds the configure path and its options.
: > "$tmp/env"
: > "$tmp/nice"
if [ -n "$nice" ]; then
    awk -v q="'" '
        { sub(/[[:space:]]*\\$/, "") }
        !opts && /^[A-Za-z_][A-Za-z0-9_]*=/ { print > ENVF; next }
        !opts && substr($0, 1, 1) == q { opts = 1 }
        opts && $0 != "\"$@\"" { printf "%s ", $0 > ARGF }
    ' ENVF="$tmp/env" ARGF="$tmp/nice_args" "$nice"
    if [ -f "$tmp/nice_args" ]; then
        to_lines "$(cat "$tmp/nice_args")" "$nice" | LC_ALL=C sort -u > "$tmp/nice"
    fi
    [ -s "$tmp/nice" ] || { echo "config-check: no configure options found in $nice" >&2; exit 2; }
fi

printf 'installed:   %s\n             %s\n             %s options, from %s\n' \
    "$php" "${version:-?}" "$(wc -l < "$tmp/installed" | tr -d ' ')" "$how"
if [ -n "$nice" ]; then
    printf 'config.nice: %s%s\n             %s options\n' "$nice" "$found" "$(wc -l < "$tmp/nice" | tr -d ' ')"
else
    printf 'config.nice: none found (no ./config.nice, no php-%s/config.nice next to this tree or in %s)\n' \
        "${ver:-?}" "${HOME:-/root}"
fi

LC_ALL=C comm -23 "$tmp/installed" "$tmp/nice" > "$tmp/only_installed"
LC_ALL=C comm -13 "$tmp/installed" "$tmp/nice" > "$tmp/only_nice"
if [ -s "$tmp/env" ]; then
    echo
    echo "environment in config.nice (not recorded by the installed build, not compared):"
    sed 's/^/  /' "$tmp/env"
fi
if [ -n "$nice" ] && [ -s "$tmp/only_installed" ]; then
    echo
    echo "only in the installed build (missing in config.nice):"
    sed 's/^/  /' "$tmp/only_installed"
fi
if [ -s "$tmp/only_nice" ]; then
    echo
    echo "only in config.nice (the installed build was built without them):"
    sed 's/^/  /' "$tmp/only_nice"
fi

# The script with the installed build's options, in the order the build recorded.
out_dir="$(cd "$(dirname "$out")" 2>/dev/null && pwd)" || { echo "config-check: no directory for $out" >&2; exit 2; }
out_name="$(basename "$out")"
out="$out_dir/$out_name"
{
    echo "#!/bin/sh"
    echo "# Written by config-check.sh on $(date '+%d.%m.%Y %H:%M'): the configure options of"
    echo "# $php (${version:-?}), from $how."
    if [ -s "$tmp/env" ]; then
        echo "# The environment lines come from $nice (the installed build does not record them)."
    fi
    echo "# Run from inside the new PHP source tree: sh $out"
    echo
    sed 's/$/ \\/' "$tmp/env"
    echo "'./configure' \\"
    sed "s/'/'\\\\''/g; s/^/'/; s/\$/' \\\\/" "$tmp/installed_order"
    echo '"$@"'
} > "$out" || { echo "config-check: cannot write $out" >&2; exit 2; }
chmod +x "$out" 2>/dev/null || true

# Shared PECL modules of the installed PHP that this source tree bundles in ext/:
# only a hint, they are built in only when their option is added.
"$php" -m 2>/dev/null | tr 'A-Z' 'a-z' > "$tmp/modules"
: > "$tmp/pecl_hint"
for m in redis memcached memcache imagick; do
    [ -f "ext/$m/config.m4" ] || [ -f "ext/$m/config9.m4" ] || continue
    grep -qx "$m" "$tmp/modules" || continue
    grep -q -e "--enable-$m\$" -e "--enable-$m=" -e "--with-$m" "$tmp/installed" && continue
    case "$m" in
        memcached) o="--enable-memcached --with-libmemcached-dir=/usr/local --disable-memcached-sasl" ;;
        imagick) o="--with-imagick=/usr/local" ;;
        *) o="--enable-$m" ;;
    esac
    printf '  %-10s %s\n' "$m" "$o" >> "$tmp/pecl_hint"
done
if [ -s "$tmp/pecl_hint" ]; then
    echo
    echo "loaded as shared modules (extension=... in php.ini), bundled in this tree; to build them in,"
    echo "add the options after the script (sh config.installed.sh <options>) and remove the extension= lines:"
    cat "$tmp/pecl_hint"
fi

echo
if [ -z "$nice" ]; then
    echo "RESULT: nothing to compare with; written from the installed build alone."
    echo "        CFLAGS and other environment settings are not recorded by the installed"
    echo "        build: give the old config.nice as the second argument to carry them over."
    rc=1
elif [ ! -s "$tmp/only_installed" ] && [ ! -s "$tmp/only_nice" ]; then
    echo "RESULT: same options; config.nice matches the installed build."
    rc=0
else
    echo "RESULT: different; the installed build wins."
    rc=1
fi
echo "written: $out"
echo "next, from inside the new source tree: sh $out"
exit "$rc"
