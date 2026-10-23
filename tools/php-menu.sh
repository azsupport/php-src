#!/bin/sh
# php-menu.sh - choose what goes into a PHP build of this fork with dialogs, the
# way the FreeBSD ports do it with "make config": the options of lang/phpXY and
# mod_phpXY, the extensions of phpXY-extensions plus the PECL extensions this
# fork bundles, and the options of single extensions. Unlike the ports, all of it
# is built into one PHP. What needs what is checked as you choose (an extension
# that another one needs is turned on, two that cannot go together are refused),
# from the sources of every branch.
#
# Usage (FreeBSD /bin/sh; from csh run it with sh), inside the PHP source tree:
#   sh php-menu.sh                  the menu for the branch of this tree
#   sh php-menu.sh 8.4              the menu for that branch (outside a tree)
#   sh php-menu.sh --reset          start from the defaults, not the saved choices
#   sh php-menu.sh --batch [+ID -ID ID=value ...]
#                                   no dialogs: the saved choices (or the defaults),
#                                   items turned on (+GD, +REDIS.LZ4) or off (-CGI),
#                                   values typed in (PREFIX=/usr/local/php84,
#                                   MYSQL_SOCK=/tmp/mysql.sock, MYSQL_SOCK= for none)
#   sh php-menu.sh --list           the items of the branch, with their state
#
# It writes ./config.menu.sh (OUT=/path/file.sh to change): ./configure with the
# chosen options and the environment of our builds, the same form as the
# config.installed.sh of config-check.sh. When ./config.installed.sh is there
# (INSTALLED=/path to change), the menu starts from what that build has, and its
# environment and its other options (layout, php.ini paths, --build) are kept;
# the menu decides the SAPI, the build options, the extensions and the values
# typed in: the install directory (PREFIX: --prefix, the man pages in it; the
# other paths of that build inside the old directory move along) and the MySQL
# socket (MYSQL_SOCK, with a MySQL extension). Without it: our base build
# (/usr/local/phpXY, --disable-all, CLI and OPcache, nothing else) and the
# compiler flags of every build (-march of /etc/make.conf).
#
# The choices are saved as the ports save theirs, in
# /var/db/php-menu/phpXY.options (PHP_MENU_DB to change), and are the start of the
# next run. Dialogs: bsddialog (FreeBSD 14 and later), else dialog (FreeBSD 13);
# DIALOG=/path/to/one to choose.

set -u
BRANCHES="5.6 7.4 8.1 8.2 8.3 8.4"
out="${OUT:-./config.menu.sh}"
installed="${INSTALLED:-./config.installed.sh}"
db="${PHP_MENU_DB:-/var/db/php-menu}"
mk_conf="${MAKE_CONF:-/etc/make.conf}"
TAB="$(printf '\t')"

die() { echo "php-menu: $*" >&2; exit 2; }

# --- data (tools/configure/menu.py of azsupport writes it) ---
menu_data() {
    cat <<'EOF'
*	S	000	core	check	-	-	PHP %B: build options (OPcache is always built)
*	S	001	ext	check	-	-	PHP %B: extensions, built into PHP
*	S	003	curl	radio	CURL	-	curl: which libcurl
*	S	014	openssl	check	OPENSSL	-	OpenSSL options
*	S	006	gd	check	GD	-	GD options
*	S	011	mbstring	check	MBSTRING	-	mbstring options
5.6	S	008	hash	check	HASH	-	hash options
*	S	004	dba	check	DBA	-	DBA handlers
*	S	010	ldap	check	LDAP	-	LDAP options
5.6-8.3	S	009	imap	check	IMAP	-	IMAP options
*	S	016	readline	radio	READLINE	-	readline for php -a: which library
*	S	017	redis	check	REDIS	-	phpredis options
*	S	013	memcached	check	MEMCACHED	-	php-memcached options
*	S	012	memcache	check	MEMCACHE	-	php-memcache options
*	I	core	000	CLI	1	-	--disable-cli	Build CLI version	bin/php: scripts, cron, composer; config-check.sh runs it
*	I	core	001	APACHE	0	--with-apxs2=/usr/local/sbin/apxs	-	Apache 2 module mod_php (www/mod_phpXY)	libphp in the Apache modules directory; a non-ZTS module needs the prefork MPM
*	I	core	002	FPM	0	--enable-fpm --with-fpm-user=www --with-fpm-group=www --localstatedir=/var	-	Build FPM version	sbin/php-fpm; pid and error_log relative to /var
*	I	core	003	CGI	0	--enable-cgi	--disable-cgi	Build CGI version	bin/php-cgi: FastCGI without FPM, suPHP, mod_fcgid
*	I	core	004	EMBED	0	--enable-embed	-	Build embedded library	libphp for programs that embed PHP; only if one links with it
5.6	I	core	005	PHPDBG	0	--enable-phpdbg	-	Interactive PHP debugger	bin/phpdbg; off by default in 5.6
5.6-7.4	I	core	007	ZTS	0	--enable-maintainer-zts	-	Force Zend Thread Safety (ZTS) build	for Apache with the event or worker MPM; slower
*	I	core	009	DEBUG	0	--enable-debug	-	Build with debugging support	slow; for developers
*	I	core	010	DTRACE	0	--enable-dtrace	-	Build with DTrace probes	the ports turn it on in 7.4 and later; not needed on a web server
*	I	core	011	IPV6	1	-	--disable-ipv6	IPv6 protocol support	on by default in PHP (the ports turn it off)
5.6	I	core	013	PCRE	0	--with-pcre-regex=/usr/local	-	Use system pcre instead of bundled one	the bundled PCRE 8.45 is the last release: not needed (package pcre)
*	I	ext	001	BCMATH	0	--enable-bcmath	-	bc style precision math functions	-
*	I	ext	002	BZ2	0	--with-bz2	-	bzip2 library support	bzip2 of the base system
*	I	ext	003	CALENDAR	0	--enable-calendar	-	calendar conversion support	-
*	I	ext	004	CTYPE	0	--enable-ctype	-	ctype functions	-
*	I	ext	005	CURL	0	-	-	CURL support	which libcurl: next screen
*	I	ext	006	DBA	0	--enable-dba	-	dba support	handlers: next screen
*	I	ext	007	DOM	0	--enable-dom	-	DOM support	-
*	I	ext	008	ENCHANT	0	--with-enchant=/usr/local	-	Enchant spelling support	package enchant2
*	I	ext	010	EXIF	0	--enable-exif	-	EXIF support	photo orientation and metadata (WordPress)
*	I	ext	012	FILEINFO	0	--enable-fileinfo	-	fileinfo support	mime types of uploads; magic database built in
*	I	ext	013	FILTER	0	--enable-filter	-	input filter support	-
*	I	ext	014	FTP	0	--enable-ftp	-	FTP support	-
5.6	I	ext	015	GD	0	--with-gd	-	GD library support	libgd of PHP; formats: next screen
*	I	ext	016	GETTEXT	0	--with-gettext=/usr/local	-	gettext library support	package gettext-runtime
*	I	ext	017	GMAGICK	0	--with-gmagick=/usr/local	-	GraphicsMagick image library (Gmagick, PECL)	package GraphicsMagick; not with imagick
*	I	ext	018	GMP	0	--with-gmp=/usr/local	-	GNU MP support	package gmp
5.6	I	ext	019	HASH	0	--enable-hash	-	HASH Message Digest Framework	built in from PHP 7.4; mhash: next screen
*	I	ext	020	ICONV	0	--with-iconv=/usr/local	-	iconv support	GNU libiconv (package libiconv): //TRANSLIT as on Linux
*	I	ext	021	IGBINARY	0	--enable-igbinary	-	Binary serializer (igbinary, PECL)	-
*	I	ext	022	IMAGICK	0	--with-imagick=/usr/local	-	ImageMagick image library (Imagick, PECL)	package ImageMagick7
5.6-8.3	I	ext	023	IMAP	0	--with-imap=/usr/local	-	IMAP support	package cclient (built with SSL)
5.6	I	ext	024	INTERBASE	0	--with-interbase=/usr/local	-	Interbase 6 database support (Firebird)	Firebird client package (firebirdNN-client)
5.6	I	ext	025	INTL	0	--enable-intl --with-icu-dir=/usr/local	-	Internationalization(ICU)	package icu; PHP 5.6 with ICU 7x is untested
5.6-7.4	I	ext	026	JSON	0	--enable-json	-	JavaScript Object Serialization support	built in from PHP 8.0
*	I	ext	027	LDAP	0	--with-ldap=/usr/local	-	OpenLDAP support	package openldap26-client
5.6	I	ext	028	LIBXML	0	--enable-libxml --with-libxml-dir=/usr/local	-	libxml2 support (needed by the XML extensions)	package libxml2
5.6	I	ext	029	MBSTRING	0	--enable-mbstring	-	multibyte string support	oniguruma built in
5.6	I	ext	030	MCRYPT	0	--with-mcrypt=/usr/local	-	Encryption support	package libmcrypt
*	I	ext	031	MEMCACHE	0	--enable-memcache	-	memcache client, the old one (PECL)	-
*	I	ext	032	MEMCACHED	0	--enable-memcached --with-libmemcached-dir=/usr/local	-	memcached client on libmemcached (PECL)	package libmemcached
5.6	I	ext	033	MSSQL	0	--with-mssql=/usr/local	-	MS-SQL database support	package freetds
5.6	I	ext	034	MYSQL	0	--with-mysql	-	MySQL database support	on mysqlnd: no MySQL client needed
5.6	I	ext	035	MYSQLI	0	--with-mysqli	-	MySQLi database support	on mysqlnd: no MySQL client needed
*	I	ext	036	ODBC	0	--with-unixODBC=/usr/local	-	ODBC support	package unixODBC
5.6	I	ext	037	OPENSSL	0	--with-openssl=/usr	-	SSL/TLS support via OpenSSL	OpenSSL of the base system
*	I	ext	039	PCNTL	0	--enable-pcntl	-	pcntl support (CLI only)	CLI only: daemons and queue workers
*	I	ext	040	PDO	0	--enable-pdo	-	PHP Data Objects Interface (PDO)	-
*	I	ext	041	PDO_DBLIB	0	--with-pdo-dblib=/usr/local	-	PDO DBLIB-DB driver	package freetds
*	I	ext	042	PDO_FIREBIRD	0	--with-pdo-firebird=/usr/local	-	PDO Firebird driver	Firebird client package (firebirdNN-client)
5.6	I	ext	043	PDO_MYSQL	0	--with-pdo-mysql	-	PDO MySQL driver	on mysqlnd: no MySQL client needed
*	I	ext	044	PDO_ODBC	0	--with-pdo-odbc=unixODBC,/usr/local	-	PDO ODBC driver	package unixODBC
5.6	I	ext	045	PDO_PGSQL	0	--with-pdo-pgsql=/usr/local	-	PDO PostgreSQL driver	PostgreSQL client package (postgresqlNN-client)
5.6	I	ext	046	PDO_SQLITE	0	--with-pdo-sqlite	-	PDO sqlite driver	SQLite built in
5.6	I	ext	047	PGSQL	0	--with-pgsql=/usr/local	-	PostgreSQL database support	PostgreSQL client package (postgresqlNN-client)
*	I	ext	048	PHAR	0	--enable-phar	-	phar support	needed by composer
*	I	ext	049	POSIX	0	--enable-posix	-	POSIX-like functions	posix_*: CLI scripts, composer
5.6-8.3	I	ext	050	PSPELL	0	--with-pspell=/usr/local	-	pspell support	package aspell
*	I	ext	051	READLINE	0	-	-	readline support (CLI only)	only for php -a; library: next screen
5.6	I	ext	052	RECODE	0	--with-recode=/usr/local	-	recode support	package recode
*	I	ext	053	REDIS	0	--enable-redis	-	Redis client (phpredis, PECL)	serializers, compression, sessions: next screen
*	I	ext	054	SESSION	0	--enable-session	-	session support	needed by almost every site
*	I	ext	055	SHMOP	0	--enable-shmop	-	shmop support	-
*	I	ext	056	SIMPLEXML	0	--enable-simplexml	-	simplexml support	-
*	I	ext	057	SNMP	0	--with-snmp=/usr/local	-	SNMP support	package net-snmp
*	I	ext	058	SOAP	0	--enable-soap	-	SOAP support	-
*	I	ext	059	SOCKETS	0	--enable-sockets	-	sockets support	-
5.6	I	ext	061	SQLITE3	0	--with-sqlite3	-	sqlite3 support	SQLite built in
5.6	I	ext	063	SYBASE_CT	0	--with-sybase-ct=/usr/local	-	Sybase database support	package freetds
*	I	ext	064	SYSVMSG	0	--enable-sysvmsg	-	System V message support	-
*	I	ext	065	SYSVSEM	0	--enable-sysvsem	-	System V semaphore support	-
*	I	ext	066	SYSVSHM	0	--enable-sysvshm	-	System V shared memory support	-
*	I	ext	067	TIDY	0	--with-tidy=/usr/local	-	TIDY support	package tidy-html5
*	I	ext	068	TOKENIZER	0	--enable-tokenizer	-	tokenizer support	needed by composer packages, Laravel, Symfony
5.6	I	ext	069	WDDX	0	--enable-wddx	-	WDDX support (implies XML)	removed from PHP in 7.4
*	I	ext	070	XML	0	--enable-xml	-	XML support	-
*	I	ext	071	XMLREADER	0	--enable-xmlreader	-	XMLReader support	-
5.6-7.4	I	ext	072	XMLRPC	0	--with-xmlrpc	-	XMLRPC-EPI support	removed from PHP in 8.0
*	I	ext	073	XMLWRITER	0	--enable-xmlwriter	-	XMLWriter support	-
5.6	I	ext	074	XSL	0	--with-xsl=/usr/local	-	XSL support (Implies DOM)	package libxslt
5.6	I	ext	075	ZIP	0	--enable-zip	-	ZIP support	libzip built in
5.6	I	ext	076	ZLIB	0	--with-zlib=/usr	-	ZLIB support	zlib of the base system
*	I	curl	000	CURL.BUNDLED	1	--with-curl=bundled	-	curl bundled in the fork, built into PHP	static, with the OpenSSL of the build (3.0 or later: FreeBSD 14 and later); packages libnghttp2 brotli zstd libidn2 libpsl
*	I	curl	001	CURL.SYSTEM	0	--with-curl=/usr/local	-	libcurl of ftp/curl, as the ports	package curl; for FreeBSD 13 with OpenSSL 1.1.1 in base
*	I	openssl	000	OPENSSL.LEGACY	1	--with-openssl-legacy-provider	-	Load the OpenSSL legacy provider	RC4, Blowfish, DES, CAST5, MD4 with OpenSSL 3 (sites that encrypt with RC4)
*	I	openssl	001	OPENSSL.SYSCIPHERS	0	--with-system-ciphers	-	Use the system default cipher list	instead of the list hardcoded in PHP
5.6	I	gd	000	GD.JPEG	1	--with-jpeg-dir=/usr/local	-	JPEG support (mozjpeg)	package mozjpeg
5.6	I	gd	001	GD.PNG	1	--with-png-dir=/usr/local	-	PNG support	package png
5.6	I	gd	002	GD.FREETYPE	1	--with-freetype-dir=/usr/local	-	FreeType 2 support	package freetype2
5.6	I	gd	003	GD.X11	0	--with-xpm-dir=/usr/local	-	Enable XPM support	package libXpm
5.6	I	gd	004	GD.VPX	0	--with-vpx-dir=/usr/local	-	Enable VP8 codec support	package libvpx
5.6	I	gd	005	GD.T1LIB	0	--with-t1lib=/usr/local	-	Include T1lib support	PostScript Type 1 fonts (imagepstext); package t1lib
5.6	I	gd	006	GD.TRUETYPE	0	--enable-gd-native-ttf	-	Enable TrueType string function	-
5.6	I	gd	007	GD.JIS	0	--enable-gd-jis-conv	-	Enable JIS-mapped Japanese font support	-
5.6	I	mbstring	000	MBSTRING.REGEX	1	-	--disable-mbregex	Enable multibyte regex support	mb_ereg_*; 5.6 has oniguruma built in
5.6	I	hash	000	HASH.MHASH	1	--with-mhash	-	mhash compatibility functions (mhash_*)	no library; the php56-hash port had it
*	I	dba	000	DBA.CDB	1	-	--without-cdb	cdb database support	built in
*	I	dba	001	DBA.INIFILE	1	-	--disable-inifile	INI file support	built in
*	I	dba	002	DBA.FLATFILE	1	-	--disable-flatfile	flatfile support	built in
*	I	dba	003	DBA.DB4	0	--with-db4=/usr/local	-	Berkeley DB4 support	package db18
*	I	dba	004	DBA.GDBM	0	--with-gdbm=/usr/local	-	GDBM database support	package gdbm
*	I	dba	005	DBA.QDBM	0	--with-qdbm=/usr/local	-	QDBM database support	package qdbm
*	I	dba	006	DBA.TOKYO	0	--with-tcadb=/usr/local	-	Tokyo Cabinet database support	package tokyocabinet
*	I	ldap	000	LDAP.SASL	0	--with-ldap-sasl	-	SASL authentication support	package cyrus-sasl
5.6-8.3	I	imap	000	IMAP.SSL	1	--with-imap-ssl=/usr	-	IMAP over SSL	OpenSSL of base
*	I	readline	000	READLINE.READLINE	1	--with-readline=/usr/local	-	GNU readline (devel/readline)	package readline
*	I	readline	001	READLINE.LIBEDIT	0	--with-libedit	-	libedit (as the ports of 8.x)	package libedit
*	I	redis	000	REDIS.SESSION	1	-	--disable-redis-session	Sessions in Redis (session.save_handler=redis)	-
*	I	redis	002	REDIS.IGBINARY	1	--enable-redis-igbinary	-	Build with Igbinary serializer	-
*	I	redis	005	REDIS.LZF	0	--enable-redis-lzf --with-liblzf	-	Build with lzf support	package liblzf
*	I	memcached	000	MEMCACHED.SESSION	1	-	--disable-memcached-session	Sessions in memcached	-
*	I	memcached	001	MEMCACHED.IGBINARY	1	--enable-memcached-igbinary	-	Binary serializer support	-
*	I	memcached	002	MEMCACHED.JSON	0	--enable-memcached-json	-	JSON serializer support	needs the json extension (5.6, 7.4)
*	I	memcached	003	MEMCACHED.PROTOCOL	0	--enable-memcached-protocol	-	MemcachedServer class (protocol)	package libevent; the port builds it
*	I	memcached	004	MEMCACHED.SASL	0	-	--disable-memcached-sasl	SASL authentication support	package cyrus-sasl; on by default in php-memcached and the port
*	I	memcache	000	MEMCACHE.SESSION	1	-	--disable-memcache-session	Sessions in memcache	-
5.6	R	DOM	LIBXML	ext/dom/config.m4:16 AC_MSG_ERROR, ext/dom/config.m4:34 PHP_ADD_EXTENSION_DEP
5.6	R	MEMCACHE.SESSION	SESSION	ext/memcache/config9.m4:98 PHP_ADD_EXTENSION_DEP
5.6	R	MEMCACHED.IGBINARY	IGBINARY	ext/memcached/config.m4:250 PHP_ADD_EXTENSION_DEP, ext/memcached/php_memcached.c:4177 ZEND_MOD_REQUIRED
5.6-7.4	R	MEMCACHED.JSON	JSON	php_json_encode of the json extension
5.6	R	MEMCACHED.SESSION	SESSION	ext/memcached/config.m4:236 PHP_ADD_EXTENSION_DEP, ext/memcached/php_memcached.c:4174 ZEND_MOD_REQUIRED
5.6	R	PDO_DBLIB	PDO	ext/pdo_dblib/config.m4:11 AC_MSG_ERROR, ext/pdo_dblib/config.m4:85 PHP_ADD_EXTENSION_DEP, ext/pdo_dblib/pdo_dblib.c:44 ZEND_MOD_REQUIRED
5.6	R	PDO_FIREBIRD	PDO	ext/pdo_firebird/config.m4:64 PHP_ADD_EXTENSION_DEP, ext/pdo_firebird/config.m4:8 AC_MSG_ERROR, ext/pdo_firebird/pdo_firebird.c:39 ZEND_MOD_REQUIRED
5.6	R	PDO_MYSQL	PDO	ext/pdo_mysql/config.m4:150 PHP_ADD_EXTENSION_DEP, ext/pdo_mysql/config.m4:18 AC_MSG_ERROR, ext/pdo_mysql/pdo_mysql.c:228 ZEND_MOD_REQUIRED
5.6	R	PDO_ODBC	PDO	ext/pdo_odbc/config.m4:172 PHP_ADD_EXTENSION_DEP, ext/pdo_odbc/config.m4:41 AC_MSG_ERROR, ext/pdo_odbc/pdo_odbc.c:42 ZEND_MOD_REQUIRED
5.6	R	PDO_PGSQL	PDO	ext/pdo_pgsql/config.m4:12 AC_MSG_ERROR, ext/pdo_pgsql/config.m4:121 PHP_ADD_EXTENSION_DEP, ext/pdo_pgsql/pdo_pgsql.c:52 ZEND_MOD_REQUIRED
5.6	R	PDO_SQLITE	PDO	ext/pdo_sqlite/config.m4:110 PHP_ADD_EXTENSION_DEP, ext/pdo_sqlite/config.m4:13 AC_MSG_ERROR, ext/pdo_sqlite/pdo_sqlite.c:46 ZEND_MOD_REQUIRED
5.6	R	PDO_SQLITE	SQLITE3	ext/pdo_sqlite/config.m4:98 PHP_ADD_EXTENSION_DEP
5.6	R	REDIS	HASH	ext/redis/config.m4:147 PHP_ADD_EXTENSION_DEP
5.6	R	REDIS.IGBINARY	IGBINARY	ext/redis/config.m4:60 PHP_ADD_EXTENSION_DEP, ext/redis/redis.c:493 ZEND_MOD_REQUIRED
5.6	R	REDIS.SESSION	SESSION	ext/redis/redis.c:496 ZEND_MOD_REQUIRED
5.6	R	SIMPLEXML	LIBXML	ext/simplexml/config.m4:15 AC_MSG_ERROR, ext/simplexml/config.m4:26 PHP_ADD_EXTENSION_DEP
5.6	R	SOAP	LIBXML	ext/soap/config.m4:15 AC_MSG_ERROR
5.6	R	WDDX	LIBXML	ext/wddx/config.m4:58 PHP_ADD_EXTENSION_DEP
5.6	R	XML	LIBXML	ext/xml/config.m4:24 AC_MSG_ERROR, ext/xml/config.m4:29 PHP_ADD_EXTENSION_DEP
5.6	R	XMLREADER	LIBXML	ext/xmlreader/config.m4:16 AC_MSG_ERROR, ext/xmlreader/php_xmlreader.c:326 ZEND_MOD_REQUIRED
5.6	R	XMLRPC	LIBXML	ext/xmlrpc/config.m4:26 PHP_ADD_EXTENSION_DEP
5.6	R	XMLWRITER	LIBXML	ext/xmlwriter/config.m4:16 AC_MSG_ERROR
*	R	XSL	DOM	ext/xsl uses DOM
5.6	R	XSL	LIBXML	ext/xsl/config.m4:12 AC_MSG_ERROR, ext/xsl/config.m4:66 PHP_ADD_EXTENSION_DEP, ext/xsl/php_xsl.c:43 ZEND_MOD_REQUIRED
*	X	APACHE	EMBED	build/php.m4 PHP_SELECT_SAPI
*	X	EMBED	APACHE	build/php.m4 PHP_SELECT_SAPI
*	X	GMAGICK	IMAGICK	ext/gmagick/config.m4:7 AC_MSG_ERROR
*	X	IMAGICK	GMAGICK	ext/gmagick/config.m4:7 AC_MSG_ERROR, ext/imagick/imagick.c:1306 ZEND_MOD_CONFLICTS
*	D	CURL.BUNDLED	ossl3
*	D	CURL.SYSTEM	!ossl3
*	E	CTYPE
*	E	DOM
*	E	FILEINFO
*	E	FILTER
5.6	E	HASH
*	E	ICONV
5.6-7.4	E	JSON
*	E	LIBXML
*	E	PDO
*	E	PDO_SQLITE
*	E	PHAR
*	E	POSIX
*	E	SESSION
*	E	SIMPLEXML
*	E	SQLITE3
*	E	TOKENIZER
*	E	XML
*	E	XMLREADER
*	E	XMLWRITER
5.6	O	--disable-ODBCRouter
*	O	--disable-adabas
*	O	--disable-apxs2
*	O	--disable-bcmath
5.6	O	--disable-birdstep
*	O	--disable-bz2
*	O	--disable-calendar
*	O	--disable-cdb
*	O	--disable-cgi
*	O	--disable-ctype
*	O	--disable-curl
*	O	--disable-custom-odbc
*	O	--disable-db1
*	O	--disable-db2
*	O	--disable-db3
*	O	--disable-db4
*	O	--disable-dba
*	O	--disable-dbm
*	O	--disable-dbmaker
*	O	--disable-debug
*	O	--disable-dom
*	O	--disable-embed
5.6	O	--disable-embedded-mysqli
*	O	--disable-empress
*	O	--disable-empress-bcs
*	O	--disable-enchant
*	O	--disable-esoob
*	O	--disable-exif
*	O	--disable-fileinfo
*	O	--disable-filter
*	O	--disable-flatfile
*	O	--disable-fpm
*	O	--disable-fpm-acl
*	O	--disable-fpm-group
*	O	--disable-fpm-systemd
*	O	--disable-fpm-user
5.6	O	--disable-freetype-dir
*	O	--disable-ftp
*	O	--disable-gd
*	O	--disable-gd-jis-conv
5.6	O	--disable-gd-native-ttf
*	O	--disable-gdbm
*	O	--disable-gettext
*	O	--disable-gmagick
*	O	--disable-gmp
5.6	O	--disable-hash
*	O	--disable-ibm-db2
*	O	--disable-iconv
5.6-7.4	O	--disable-iconv-dir
*	O	--disable-igbinary
*	O	--disable-imagick
5.6-8.3	O	--disable-imap
5.6-8.3	O	--disable-imap-ssl
*	O	--disable-inifile
5.6	O	--disable-interbase
*	O	--disable-intl
*	O	--disable-iodbc
*	O	--disable-ipv6
5.6	O	--disable-jpeg-dir
5.6-7.4	O	--disable-json
5.6-8.3	O	--disable-kerberos
*	O	--disable-ldap
*	O	--disable-ldap-sasl
*	O	--disable-libedit
5.6	O	--disable-libexpat-dir
*	O	--disable-liblzf
5.6	O	--disable-libmbfl
*	O	--disable-libmemcached-dir
*	O	--disable-libxml
5.6	O	--disable-libxml-dir
5.6	O	--disable-libzip
*	O	--disable-litespeed
5.6-7.4	O	--disable-maintainer-zts
*	O	--disable-mbregex
5.6	O	--disable-mbregex-backtrack
*	O	--disable-mbstring
*	O	--disable-mcrypt
*	O	--disable-memcache
*	O	--disable-memcache-session
*	O	--disable-memcached
*	O	--disable-memcached-igbinary
*	O	--disable-memcached-json
*	O	--disable-memcached-msgpack
*	O	--disable-memcached-protocol
*	O	--disable-memcached-sasl
*	O	--disable-memcached-session
*	O	--disable-mhash
*	O	--disable-mm
5.6	O	--disable-mssql
5.6	O	--disable-mysql
*	O	--disable-mysql-sock
*	O	--disable-mysqli
*	O	--disable-mysqlnd
*	O	--disable-mysqlnd-compression-support
*	O	--disable-ndbm
5.6-8.3	O	--disable-oci8
*	O	--disable-odbcver
5.6	O	--disable-onig
*	O	--disable-opcache-jit
*	O	--disable-openssl
*	O	--disable-openssl-dir
*	O	--disable-openssl-legacy-provider
*	O	--disable-pcntl
5.6	O	--disable-pcre-dir
5.6	O	--disable-pcre-regex
*	O	--disable-pdo
*	O	--disable-pdo-dblib
*	O	--disable-pdo-firebird
*	O	--disable-pdo-mysql
5.6-8.3	O	--disable-pdo-oci
*	O	--disable-pdo-odbc
*	O	--disable-pdo-pgsql
*	O	--disable-pdo-sqlite
*	O	--disable-pgsql
*	O	--disable-phar
*	O	--disable-phpdbg
*	O	--disable-phpdbg-debug
5.6	O	--disable-png-dir
*	O	--disable-posix
5.6-8.3	O	--disable-pspell
*	O	--disable-qdbm
*	O	--disable-readline
5.6	O	--disable-recode
*	O	--disable-redis
*	O	--disable-redis-igbinary
*	O	--disable-redis-lzf
*	O	--disable-redis-session
5.6	O	--disable-regex
*	O	--disable-sapdb
*	O	--disable-session
*	O	--disable-shmop
*	O	--disable-simplexml
*	O	--disable-snmp
*	O	--disable-soap
*	O	--disable-sockets
*	O	--disable-solid
*	O	--disable-sqlite3
5.6	O	--disable-sybase-ct
*	O	--disable-system-ciphers
*	O	--disable-sysvmsg
*	O	--disable-sysvsem
*	O	--disable-sysvshm
5.6	O	--disable-t1lib
*	O	--disable-tcadb
*	O	--disable-tidy
*	O	--disable-tokenizer
*	O	--disable-unixODBC
5.6	O	--disable-vpx-dir
5.6	O	--disable-wddx
*	O	--disable-xml
*	O	--disable-xmlreader
5.6-7.4	O	--disable-xmlrpc
*	O	--disable-xmlwriter
5.6	O	--disable-xpm-dir
*	O	--disable-xsl
*	O	--disable-zip
*	O	--disable-zlib
*	O	--disable-zlib-dir
*	O	--disable-zts
5.6	O	--enable-ODBCRouter
*	O	--enable-adabas
*	O	--enable-apxs2
*	O	--enable-bcmath
5.6	O	--enable-birdstep
*	O	--enable-bz2
*	O	--enable-calendar
*	O	--enable-cdb
*	O	--enable-cgi
*	O	--enable-ctype
*	O	--enable-curl
*	O	--enable-custom-odbc
*	O	--enable-db1
*	O	--enable-db2
*	O	--enable-db3
*	O	--enable-db4
*	O	--enable-dba
*	O	--enable-dbm
*	O	--enable-dbmaker
*	O	--enable-debug
*	O	--enable-dom
*	O	--enable-dtrace
*	O	--enable-embed
5.6	O	--enable-embedded-mysqli
*	O	--enable-empress
*	O	--enable-empress-bcs
*	O	--enable-enchant
*	O	--enable-esoob
*	O	--enable-exif
*	O	--enable-fileinfo
*	O	--enable-filter
*	O	--enable-flatfile
*	O	--enable-fpm
*	O	--enable-fpm-acl
*	O	--enable-fpm-group
*	O	--enable-fpm-systemd
*	O	--enable-fpm-user
5.6	O	--enable-freetype-dir
*	O	--enable-ftp
*	O	--enable-gd
*	O	--enable-gd-jis-conv
5.6	O	--enable-gd-native-ttf
*	O	--enable-gdbm
*	O	--enable-gettext
*	O	--enable-gmagick
*	O	--enable-gmp
5.6	O	--enable-hash
*	O	--enable-ibm-db2
*	O	--enable-iconv
5.6-7.4	O	--enable-iconv-dir
*	O	--enable-igbinary
*	O	--enable-imagick
5.6-8.3	O	--enable-imap
5.6-8.3	O	--enable-imap-ssl
*	O	--enable-inifile
5.6	O	--enable-interbase
*	O	--enable-intl
*	O	--enable-iodbc
*	O	--enable-ipv6
5.6	O	--enable-jpeg-dir
5.6-7.4	O	--enable-json
5.6-8.3	O	--enable-kerberos
*	O	--enable-ldap
*	O	--enable-ldap-sasl
*	O	--enable-libedit
5.6	O	--enable-libexpat-dir
*	O	--enable-liblzf
5.6	O	--enable-libmbfl
*	O	--enable-libmemcached-dir
*	O	--enable-libxml
5.6	O	--enable-libxml-dir
5.6	O	--enable-libzip
*	O	--enable-litespeed
*	O	--enable-maintainer-zts
*	O	--enable-mbregex
5.6	O	--enable-mbregex-backtrack
*	O	--enable-mbstring
*	O	--enable-mcrypt
*	O	--enable-memcache
*	O	--enable-memcache-session
*	O	--enable-memcached
*	O	--enable-memcached-igbinary
*	O	--enable-memcached-json
*	O	--enable-memcached-msgpack
*	O	--enable-memcached-protocol
*	O	--enable-memcached-sasl
*	O	--enable-memcached-session
*	O	--enable-mhash
*	O	--enable-mm
5.6	O	--enable-mssql
5.6	O	--enable-mysql
*	O	--enable-mysql-sock
*	O	--enable-mysqli
*	O	--enable-mysqlnd
*	O	--enable-mysqlnd-compression-support
*	O	--enable-ndbm
5.6-8.3	O	--enable-oci8
*	O	--enable-odbcver
5.6	O	--enable-onig
*	O	--enable-opcache-jit
*	O	--enable-openssl
*	O	--enable-openssl-dir
*	O	--enable-openssl-legacy-provider
*	O	--enable-pcntl
5.6	O	--enable-pcre-dir
5.6	O	--enable-pcre-regex
*	O	--enable-pdo
*	O	--enable-pdo-dblib
*	O	--enable-pdo-firebird
*	O	--enable-pdo-mysql
5.6-8.3	O	--enable-pdo-oci
*	O	--enable-pdo-odbc
*	O	--enable-pdo-pgsql
*	O	--enable-pdo-sqlite
*	O	--enable-pgsql
*	O	--enable-phar
*	O	--enable-phpdbg
*	O	--enable-phpdbg-debug
5.6	O	--enable-png-dir
*	O	--enable-posix
5.6-8.3	O	--enable-pspell
*	O	--enable-qdbm
*	O	--enable-readline
5.6	O	--enable-recode
*	O	--enable-redis
*	O	--enable-redis-igbinary
*	O	--enable-redis-lzf
*	O	--enable-redis-session
5.6	O	--enable-regex
*	O	--enable-sapdb
*	O	--enable-session
*	O	--enable-shmop
*	O	--enable-simplexml
*	O	--enable-snmp
*	O	--enable-soap
*	O	--enable-sockets
*	O	--enable-solid
*	O	--enable-sqlite3
5.6	O	--enable-sybase-ct
*	O	--enable-system-ciphers
*	O	--enable-sysvmsg
*	O	--enable-sysvsem
*	O	--enable-sysvshm
5.6	O	--enable-t1lib
*	O	--enable-tcadb
*	O	--enable-tidy
*	O	--enable-tokenizer
*	O	--enable-unixODBC
5.6	O	--enable-vpx-dir
5.6	O	--enable-wddx
*	O	--enable-xml
*	O	--enable-xmlreader
5.6-7.4	O	--enable-xmlrpc
*	O	--enable-xmlwriter
5.6	O	--enable-xpm-dir
*	O	--enable-xsl
*	O	--enable-zip
*	O	--enable-zlib
*	O	--enable-zlib-dir
*	O	--enable-zts
*	O	--infodir
*	O	--localstatedir
*	O	--mandir
*	O	--prefix
5.6	O	--with-ODBCRouter
*	O	--with-adabas
*	O	--with-apxs2
*	O	--with-bcmath
5.6	O	--with-birdstep
*	O	--with-bz2
*	O	--with-calendar
*	O	--with-cdb
*	O	--with-cgi
*	O	--with-ctype
*	O	--with-curl
*	O	--with-custom-odbc
*	O	--with-db1
*	O	--with-db2
*	O	--with-db3
*	O	--with-db4
*	O	--with-dba
*	O	--with-dbm
*	O	--with-dbmaker
*	O	--with-dom
*	O	--with-embed
5.6	O	--with-embedded-mysqli
*	O	--with-empress
*	O	--with-empress-bcs
*	O	--with-enchant
*	O	--with-esoob
*	O	--with-exif
*	O	--with-external-pcre
*	O	--with-fileinfo
*	O	--with-filter
*	O	--with-flatfile
*	O	--with-fpm
*	O	--with-fpm-group
*	O	--with-fpm-systemd
*	O	--with-fpm-user
5.6	O	--with-freetype-dir
*	O	--with-ftp
*	O	--with-gd
*	O	--with-gd-jis-conv
5.6	O	--with-gd-native-ttf
*	O	--with-gdbm
*	O	--with-gettext
*	O	--with-gmagick
*	O	--with-gmp
5.6	O	--with-hash
*	O	--with-ibm-db2
*	O	--with-iconv
5.6	O	--with-icu-dir
*	O	--with-igbinary
*	O	--with-imagick
5.6-8.3	O	--with-imap
5.6-8.3	O	--with-imap-ssl
*	O	--with-inifile
5.6	O	--with-interbase
*	O	--with-intl
*	O	--with-iodbc
5.6	O	--with-jpeg-dir
5.6-7.4	O	--with-json
5.6-8.3	O	--with-kerberos
*	O	--with-ldap
*	O	--with-ldap-sasl
*	O	--with-libedit
5.6	O	--with-libexpat-dir
*	O	--with-liblzf
5.6	O	--with-libmbfl
*	O	--with-libmemcached-dir
*	O	--with-libxml
*	O	--with-libxml-dir
*	O	--with-litespeed
5.6-7.4	O	--with-maintainer-zts
*	O	--with-mbregex
5.6	O	--with-mbregex-backtrack
*	O	--with-mbstring
*	O	--with-mcrypt
*	O	--with-memcache
*	O	--with-memcache-session
*	O	--with-memcached
*	O	--with-memcached-igbinary
*	O	--with-memcached-json
*	O	--with-memcached-msgpack
*	O	--with-memcached-protocol
*	O	--with-memcached-sasl
*	O	--with-memcached-session
*	O	--with-mhash
*	O	--with-mm
5.6	O	--with-mssql
5.6	O	--with-mysql
*	O	--with-mysql-sock
*	O	--with-mysqli
*	O	--with-mysqlnd
*	O	--with-mysqlnd-compression-support
*	O	--with-ndbm
5.6-8.3	O	--with-oci8
*	O	--with-odbcver
5.6	O	--with-onig
*	O	--with-opcache
*	O	--with-openssl
*	O	--with-openssl-argon2
*	O	--with-openssl-legacy-provider
*	O	--with-password-argon2
*	O	--with-pcntl
*	O	--with-pcre-jit
*	O	--with-pcre-regex
*	O	--with-pdo
*	O	--with-pdo-dblib
*	O	--with-pdo-firebird
*	O	--with-pdo-mysql
5.6-8.3	O	--with-pdo-oci
*	O	--with-pdo-odbc
*	O	--with-pdo-pgsql
*	O	--with-pdo-sqlite
*	O	--with-pgsql
*	O	--with-phar
*	O	--with-phpdbg
*	O	--with-phpdbg-debug
5.6	O	--with-png-dir
*	O	--with-posix
5.6-8.3	O	--with-pspell
*	O	--with-qdbm
*	O	--with-readline
5.6	O	--with-recode
*	O	--with-redis
*	O	--with-redis-igbinary
*	O	--with-redis-lzf
*	O	--with-redis-session
5.6	O	--with-regex
*	O	--with-sapdb
*	O	--with-session
*	O	--with-shmop
*	O	--with-simplexml
*	O	--with-snmp
*	O	--with-soap
*	O	--with-sockets
*	O	--with-solid
*	O	--with-sqlite3
5.6	O	--with-sybase-ct
*	O	--with-system-ciphers
*	O	--with-sysvmsg
*	O	--with-sysvsem
*	O	--with-sysvshm
5.6	O	--with-t1lib
*	O	--with-tcadb
*	O	--with-tidy
*	O	--with-tokenizer
*	O	--with-unixODBC
5.6	O	--with-vpx-dir
5.6	O	--with-wddx
*	O	--with-xml
*	O	--with-xmlreader
5.6-7.4	O	--with-xmlrpc
*	O	--with-xmlwriter
5.6	O	--with-xpm-dir
*	O	--with-xsl
*	O	--with-zip
*	O	--with-zlib
5.6	O	--without-ODBCRouter
*	O	--without-adabas
*	O	--without-apxs2
*	O	--without-bcmath
5.6	O	--without-birdstep
*	O	--without-bz2
*	O	--without-calendar
*	O	--without-cdb
*	O	--without-cgi
*	O	--without-ctype
*	O	--without-curl
*	O	--without-custom-odbc
*	O	--without-db1
*	O	--without-db2
*	O	--without-db3
*	O	--without-db4
*	O	--without-dba
*	O	--without-dbm
*	O	--without-dbmaker
*	O	--without-dom
*	O	--without-embed
5.6	O	--without-embedded-mysqli
*	O	--without-empress
*	O	--without-empress-bcs
*	O	--without-enchant
*	O	--without-esoob
*	O	--without-exif
*	O	--without-fileinfo
*	O	--without-filter
*	O	--without-flatfile
*	O	--without-fpm
*	O	--without-fpm-acl
*	O	--without-fpm-group
*	O	--without-fpm-systemd
*	O	--without-fpm-user
5.6	O	--without-freetype-dir
*	O	--without-ftp
*	O	--without-gd
*	O	--without-gd-jis-conv
5.6	O	--without-gd-native-ttf
*	O	--without-gdbm
*	O	--without-gettext
*	O	--without-gmagick
*	O	--without-gmp
5.6	O	--without-hash
*	O	--without-ibm-db2
*	O	--without-iconv
5.6-7.4	O	--without-iconv-dir
*	O	--without-igbinary
*	O	--without-imagick
5.6-8.3	O	--without-imap
5.6-8.3	O	--without-imap-ssl
*	O	--without-inifile
5.6	O	--without-interbase
*	O	--without-intl
*	O	--without-iodbc
5.6	O	--without-jpeg-dir
5.6-7.4	O	--without-json
5.6-8.3	O	--without-kerberos
*	O	--without-ldap
*	O	--without-ldap-sasl
*	O	--without-libedit
5.6	O	--without-libexpat-dir
*	O	--without-liblzf
5.6	O	--without-libmbfl
*	O	--without-libmemcached-dir
*	O	--without-libxml
5.6	O	--without-libxml-dir
5.6	O	--without-libzip
*	O	--without-litespeed
5.6-7.4	O	--without-maintainer-zts
*	O	--without-mbregex
5.6	O	--without-mbregex-backtrack
*	O	--without-mbstring
*	O	--without-mcrypt
*	O	--without-memcache
*	O	--without-memcache-session
*	O	--without-memcached
*	O	--without-memcached-igbinary
*	O	--without-memcached-json
*	O	--without-memcached-msgpack
*	O	--without-memcached-protocol
*	O	--without-memcached-sasl
*	O	--without-memcached-session
*	O	--without-mhash
*	O	--without-mm
5.6	O	--without-mssql
5.6	O	--without-mysql
*	O	--without-mysql-sock
*	O	--without-mysqli
*	O	--without-mysqlnd
*	O	--without-mysqlnd-compression-support
*	O	--without-ndbm
5.6-8.3	O	--without-oci8
*	O	--without-odbcver
5.6	O	--without-onig
*	O	--without-opcache
*	O	--without-openssl
*	O	--without-openssl-dir
*	O	--without-openssl-legacy-provider
*	O	--without-pcntl
5.6	O	--without-pcre-dir
5.6	O	--without-pcre-regex
*	O	--without-pdo
*	O	--without-pdo-dblib
*	O	--without-pdo-firebird
*	O	--without-pdo-mysql
5.6-8.3	O	--without-pdo-oci
*	O	--without-pdo-odbc
*	O	--without-pdo-pgsql
*	O	--without-pdo-sqlite
*	O	--without-pgsql
*	O	--without-phar
*	O	--without-phpdbg
*	O	--without-phpdbg-debug
5.6	O	--without-png-dir
*	O	--without-posix
5.6-8.3	O	--without-pspell
*	O	--without-qdbm
*	O	--without-readline
5.6	O	--without-recode
*	O	--without-redis
*	O	--without-redis-igbinary
*	O	--without-redis-lzf
*	O	--without-redis-session
5.6	O	--without-regex
*	O	--without-sapdb
*	O	--without-session
*	O	--without-shmop
*	O	--without-simplexml
*	O	--without-snmp
*	O	--without-soap
*	O	--without-sockets
*	O	--without-solid
*	O	--without-sqlite3
5.6	O	--without-sybase-ct
*	O	--without-system-ciphers
*	O	--without-sysvmsg
*	O	--without-sysvsem
*	O	--without-sysvshm
5.6	O	--without-t1lib
*	O	--without-tcadb
*	O	--without-tidy
*	O	--without-tokenizer
*	O	--without-unixODBC
5.6	O	--without-vpx-dir
5.6	O	--without-wddx
*	O	--without-xml
*	O	--without-xmlreader
5.6-7.4	O	--without-xmlrpc
*	O	--without-xmlwriter
5.6	O	--without-xpm-dir
*	O	--without-xsl
*	O	--without-zip
*	O	--without-zlib
*	O	--without-zlib-dir
*	V	PREFIX	/usr/local/php%S	-	Install directory	--prefix=%V --mandir=%V/man	bin, sbin, lib, include, etc (php.ini with --with-layout=GNU) and man go there
5.6	V	MYSQL_SOCK	/tmp/mysql.sock	MYSQL	MySQL socket	--with-mysql-sock=%V	default of mysql/mysqli/pdo_mysql.default_socket; 5.6 takes it only with the mysql extension; empty: none (mysqlnd uses /tmp/mysql.sock)
7.4+	S	007	gdformats	check	GD	GD.EXTERNAL=0	GD: formats of the libgd of PHP
7.4+	S	018	swoole	check	SWOOLE	-	Swoole options
7.4+	S	015	openswoole	check	OPENSWOOLE	-	OpenSwoole options
7.4+	I	core	005	PHPDBG	0	--enable-phpdbg	--disable-phpdbg	Interactive PHP debugger	bin/phpdbg; PHP builds it by default, also with --disable-all (configure reads the SAPIs first)
7.4+	I	core	013	PCRE	0	--with-external-pcre=/usr/local	-	Use system pcre instead of bundled one	the bundled PCRE2 10.49 is newer than the package pcre2: not needed
7.4	I	ext	000	ARGON2	0	--with-password-argon2=/usr/local	-	Argon2 in password_hash()	package libargon2
7.4+	I	ext	009	EXCIMER	0	--enable-excimer	-	Excimer sampling profiler (PECL)	-
7.4+	I	ext	011	FFI	0	--with-ffi	-	Foreign Function Interface support	package libffi
7.4+	I	ext	015	GD	0	--enable-gd	-	GD library support	libgd of graphics/gd or of PHP: next screen
7.4+	I	ext	025	INTL	0	--enable-intl	-	Internationalization(ICU)	package icu
7.4+	I	ext	028	LIBXML	0	--with-libxml	-	libxml2 support (needed by the XML extensions)	package libxml2
7.4+	I	ext	029	MBSTRING	0	--enable-mbstring	-	multibyte string support	mb_ereg_* need the package oniguruma: next screen
7.4+	I	ext	030	MCRYPT	0	--with-mcrypt=/usr/local	-	Encryption support	PECL mcrypt bundled in the fork; package libmcrypt
7.4+	I	ext	035	MYSQLI	0	--with-mysqli=mysqlnd	-	MySQLi database support	on mysqlnd: no MySQL client needed
7.4+	I	ext	037	OPENSSL	0	--with-openssl	-	OpenSSL support	OpenSSL of the base system
7.4+	I	ext	038	OPENSWOOLE	0	--enable-openswoole	-	OpenSwoole: coroutines, asynchronous servers (PECL)	heavy: only for applications on OpenSwoole; not with swoole
7.4+	I	ext	043	PDO_MYSQL	0	--with-pdo-mysql=mysqlnd	-	PDO MySQL driver	on mysqlnd: no MySQL client needed
7.4+	I	ext	045	PDO_PGSQL	0	--with-pdo-pgsql	-	PDO PostgreSQL driver	PostgreSQL client package (postgresqlNN-client)
7.4+	I	ext	046	PDO_SQLITE	0	--with-pdo-sqlite	-	PDO sqlite driver	package sqlite3
7.4+	I	ext	047	PGSQL	0	--with-pgsql	-	PostgreSQL database support	PostgreSQL client package (postgresqlNN-client)
7.4+	I	ext	060	SODIUM	0	--with-sodium	-	Sodium encryption support	package libsodium
7.4+	I	ext	061	SQLITE3	0	--with-sqlite3	-	sqlite3 support	package sqlite3
7.4+	I	ext	062	SWOOLE	0	--enable-swoole	-	Swoole: coroutines, asynchronous servers (PECL)	heavy: only for applications on Swoole; not with openswoole
7.4+	I	ext	074	XSL	0	--with-xsl	-	XSL support (Implies DOM)	package libxslt
7.4+	I	ext	075	ZIP	0	--with-zip	-	ZIP support	package libzip
7.4+	I	ext	076	ZLIB	0	--with-zlib	-	ZLIB support	zlib of the base system
7.4+	I	gd	008	GD.EXTERNAL	1	--with-external-gd	-	Use libgd of graphics/gd	package gd; its formats (JPEG of mozjpeg); off: the libgd of PHP with the formats of the next screen
7.4+	I	gdformats	000	GD.F_JPEG	1	--with-jpeg	-	JPEG support (mozjpeg)	package mozjpeg
7.4+	I	gdformats	001	GD.F_FREETYPE	1	--with-freetype	-	FreeType 2 support	package freetype2
7.4+	I	gdformats	002	GD.F_WEBP	1	--with-webp	-	WebP image format support	package webp
7.4+	I	gdformats	004	GD.F_X11	0	--with-xpm	-	Enable XPM support	package libXpm
7.4+	I	gdformats	005	GD.F_JIS	0	--enable-gd-jis-conv	-	Enable JIS-mapped Japanese font support	-
7.4+	I	mbstring	000	MBSTRING.REGEX	1	-	--disable-mbregex	Enable multibyte regex support	mb_ereg_*; needs the package oniguruma
7.4+	I	dba	007	DBA.LMDB	0	--with-lmdb=/usr/local	-	LMDB database support	package lmdb
7.4	I	redis	001	REDIS.JSON	1	-	--disable-redis-json	JSON serializer	needs the json extension
7.4+	I	redis	003	REDIS.LZ4	0	--enable-redis-lz4 --with-liblz4	-	Build with lz4 support	package liblz4
7.4+	I	redis	004	REDIS.ZSTD	0	--enable-redis-zstd	-	Build with zstd support	package zstd
7.4+	I	swoole	000	SWOOLE.CURL	0	--enable-swoole-curl	-	Coroutine curl hook	needs the curl extension
7.4+	I	swoole	001	SWOOLE.BROTLI	0	--enable-brotli	--disable-brotli	Brotli compression	package brotli
7.4+	I	openswoole	000	OPENSWOOLE.HTTP2	0	--enable-http2	-	HTTP/2 server	-
7.4+	I	openswoole	001	OPENSWOOLE.CARES	0	--enable-cares	-	c-ares asynchronous DNS	package c-ares
7.4+	I	openswoole	002	OPENSWOOLE.POSTGRES	0	--with-postgres	-	Coroutine PostgreSQL client	PostgreSQL client package
7.4-8.3	R	DOM	LIBXML	ext/dom/config.m4:10 AC_MSG_ERROR, ext/dom/config.m4:28 PHP_ADD_EXTENSION_DEP
7.4+	R	MEMCACHE.SESSION	SESSION	ext/memcache/config9.m4:127 PHP_ADD_EXTENSION_DEP
7.4+	R	MEMCACHED.IGBINARY	IGBINARY	ext/memcached/config.m4:211 PHP_ADD_EXTENSION_DEP, ext/memcached/php_memcached.c:4055 ZEND_MOD_REQUIRED
7.4+	R	MEMCACHED.SESSION	SESSION	ext/memcached/config.m4:197 PHP_ADD_EXTENSION_DEP, ext/memcached/php_memcached.c:4052 ZEND_MOD_REQUIRED
7.4	R	PDO_DBLIB	PDO	ext/pdo_dblib/config.m4:64 PHP_ADD_EXTENSION_DEP, ext/pdo_dblib/config.m4:9 AC_MSG_ERROR, ext/pdo_dblib/pdo_dblib.c:41 ZEND_MOD_REQUIRED
7.4	R	PDO_FIREBIRD	PDO	ext/pdo_firebird/config.m4:10 AC_MSG_ERROR, ext/pdo_firebird/config.m4:66 PHP_ADD_EXTENSION_DEP, ext/pdo_firebird/pdo_firebird.c:39 ZEND_MOD_REQUIRED
7.4	R	PDO_MYSQL	PDO	ext/pdo_mysql/config.m4:131 PHP_ADD_EXTENSION_DEP, ext/pdo_mysql/config.m4:31 AC_MSG_ERROR, ext/pdo_mysql/pdo_mysql.c:234 ZEND_MOD_REQUIRED
7.4	R	PDO_ODBC	PDO	ext/pdo_odbc/config.m4:143 PHP_ADD_EXTENSION_DEP, ext/pdo_odbc/config.m4:29 AC_MSG_ERROR, ext/pdo_odbc/pdo_odbc.c:39 ZEND_MOD_REQUIRED
7.4	R	PDO_PGSQL	PDO	ext/pdo_pgsql/config.m4:10 AC_MSG_ERROR, ext/pdo_pgsql/config.m4:89 PHP_ADD_EXTENSION_DEP, ext/pdo_pgsql/pdo_pgsql.c:45 ZEND_MOD_REQUIRED
7.4	R	PDO_SQLITE	PDO	ext/pdo_sqlite/config.m4:10 AC_MSG_ERROR, ext/pdo_sqlite/config.m4:33 PHP_ADD_EXTENSION_DEP, ext/pdo_sqlite/pdo_sqlite.c:41 ZEND_MOD_REQUIRED
7.4+	R	REDIS.IGBINARY	IGBINARY	ext/redis/config.m4:139 PHP_ADD_EXTENSION_DEP, ext/redis/redis.c:125 ZEND_MOD_REQUIRED
7.4	R	REDIS.JSON	JSON	ext/redis/config.m4:98 PHP_ADD_EXTENSION_DEP, ext/redis/redis.c:131 ZEND_MOD_REQUIRED
7.4+	R	REDIS.SESSION	SESSION	ext/redis/redis.c:134 ZEND_MOD_REQUIRED
7.4-8.3	R	SIMPLEXML	LIBXML	ext/simplexml/config.m4:10 AC_MSG_ERROR, ext/simplexml/config.m4:19 PHP_ADD_EXTENSION_DEP
7.4-8.3	R	SOAP	LIBXML	ext/soap/config.m4:9 AC_MSG_ERROR
7.4+	R	SWOOLE.CURL	CURL	hooks the curl extension
7.4-8.3	R	XML	LIBXML	ext/xml/config.m4:22 AC_MSG_ERROR, ext/xml/config.m4:27 PHP_ADD_EXTENSION_DEP
7.4	R	XMLREADER	LIBXML	ext/xmlreader/config.m4:10 AC_MSG_ERROR, ext/xmlreader/php_xmlreader.c:324 ZEND_MOD_REQUIRED
7.4	R	XMLRPC	LIBXML	ext/xmlrpc/config.m4:22 PHP_ADD_EXTENSION_DEP
7.4-8.3	R	XMLWRITER	LIBXML	ext/xmlwriter/config.m4:10 AC_MSG_ERROR
7.4	R	XSL	LIBXML	ext/xsl/config.m4:31 PHP_ADD_EXTENSION_DEP, ext/xsl/config.m4:9 AC_MSG_ERROR, ext/xsl/php_xsl.c:41 ZEND_MOD_REQUIRED
7.4+	X	OPENSWOOLE	SWOOLE	ext/openswoole/config.m4:52 AC_MSG_ERROR
7.4+	X	SWOOLE	OPENSWOOLE	ext/openswoole/config.m4:52 AC_MSG_ERROR
7.4+	O	--disable-asan
7.4+	O	--disable-brotli
7.4+	O	--disable-brotli-dir
7.4+	O	--disable-cares
7.4+	O	--disable-debug-log
7.4+	O	--disable-excimer
7.4+	O	--disable-expat
7.4+	O	--disable-external-gd
7.4+	O	--disable-external-pcre
7.4+	O	--disable-ffi
7.4+	O	--disable-freetype
7.4+	O	--disable-http2
7.4+	O	--disable-huge-code-pages
7.4+	O	--disable-jemalloc-dir
7.4+	O	--disable-jpeg
7.4+	O	--disable-liblz4
7.4+	O	--disable-libzstd
7.4+	O	--disable-lmdb
7.4+	O	--disable-openswoole
7.4+	O	--disable-password-argon2
7.4+	O	--disable-pcre-jit
7.4+	O	--disable-phpdbg-readline
7.4	O	--disable-phpdbg-webhelper
7.4+	O	--disable-postgres
7.4+	O	--disable-redis-json
7.4+	O	--disable-redis-lz4
7.4+	O	--disable-redis-msgpack
7.4+	O	--disable-redis-zstd
7.4+	O	--disable-sodium
7.4+	O	--disable-swoole
7.4+	O	--disable-swoole-coverage
7.4+	O	--disable-swoole-curl
7.4+	O	--disable-swoole-dev
7.4+	O	--disable-swoole-json
7.4+	O	--disable-system-fastlz
7.4+	O	--disable-thread-context
7.4+	O	--disable-trace-log
7.4+	O	--disable-webp
7.4+	O	--disable-xpm
7.4+	O	--disable-zstd
7.4+	O	--enable-asan
7.4+	O	--enable-brotli
7.4+	O	--enable-brotli-dir
7.4+	O	--enable-cares
7.4+	O	--enable-debug-log
7.4+	O	--enable-excimer
7.4+	O	--enable-expat
7.4+	O	--enable-external-gd
7.4+	O	--enable-external-pcre
7.4+	O	--enable-ffi
7.4+	O	--enable-freetype
7.4+	O	--enable-http2
7.4+	O	--enable-huge-code-pages
7.4+	O	--enable-jemalloc-dir
7.4+	O	--enable-jpeg
7.4+	O	--enable-liblz4
7.4+	O	--enable-libzstd
7.4+	O	--enable-lmdb
7.4+	O	--enable-openswoole
7.4+	O	--enable-password-argon2
7.4+	O	--enable-pcre-jit
7.4+	O	--enable-phpdbg-readline
7.4	O	--enable-phpdbg-webhelper
7.4+	O	--enable-postgres
7.4+	O	--enable-redis-json
7.4+	O	--enable-redis-lz4
7.4+	O	--enable-redis-msgpack
7.4+	O	--enable-redis-zstd
7.4+	O	--enable-sodium
7.4+	O	--enable-swoole
7.4+	O	--enable-swoole-coverage
7.4+	O	--enable-swoole-curl
7.4+	O	--enable-swoole-dev
7.4+	O	--enable-swoole-json
7.4+	O	--enable-system-fastlz
7.4+	O	--enable-thread-context
7.4+	O	--enable-trace-log
7.4+	O	--enable-webp
7.4+	O	--enable-xpm
7.4+	O	--enable-zstd
7.4+	O	--with-asan
7.4+	O	--with-brotli
7.4+	O	--with-brotli-dir
7.4+	O	--with-cares
7.4+	O	--with-debug-log
7.4+	O	--with-excimer
7.4+	O	--with-expat
7.4+	O	--with-external-gd
7.4+	O	--with-ffi
7.4+	O	--with-freetype
7.4+	O	--with-http2
7.4+	O	--with-huge-code-pages
7.4+	O	--with-jemalloc-dir
7.4+	O	--with-jpeg
7.4+	O	--with-liblz4
7.4+	O	--with-libzstd
7.4+	O	--with-lmdb
7.4+	O	--with-openswoole
7.4+	O	--with-phpdbg-readline
7.4	O	--with-phpdbg-webhelper
7.4+	O	--with-postgres
7.4+	O	--with-redis-json
7.4+	O	--with-redis-lz4
7.4+	O	--with-redis-msgpack
7.4+	O	--with-redis-zstd
7.4+	O	--with-sodium
7.4+	O	--with-swoole
7.4+	O	--with-swoole-coverage
7.4+	O	--with-swoole-curl
7.4+	O	--with-swoole-dev
7.4+	O	--with-swoole-json
7.4+	O	--with-system-fastlz
7.4+	O	--with-thread-context
7.4+	O	--with-trace-log
7.4+	O	--with-webp
7.4+	O	--with-xpm
7.4+	O	--with-zstd
7.4+	O	--without-asan
7.4+	O	--without-brotli
7.4+	O	--without-brotli-dir
7.4+	O	--without-cares
7.4+	O	--without-debug-log
7.4+	O	--without-excimer
7.4+	O	--without-expat
7.4+	O	--without-external-gd
7.4+	O	--without-external-pcre
7.4+	O	--without-ffi
7.4+	O	--without-freetype
7.4+	O	--without-http2
7.4+	O	--without-huge-code-pages
7.4+	O	--without-jemalloc-dir
7.4+	O	--without-jpeg
7.4+	O	--without-liblz4
7.4+	O	--without-libzstd
7.4+	O	--without-lmdb
7.4+	O	--without-openswoole
7.4+	O	--without-password-argon2
7.4+	O	--without-pcre-jit
7.4+	O	--without-phpdbg-readline
7.4	O	--without-phpdbg-webhelper
7.4+	O	--without-postgres
7.4+	O	--without-redis-json
7.4+	O	--without-redis-lz4
7.4+	O	--without-redis-msgpack
7.4+	O	--without-redis-zstd
7.4+	O	--without-sodium
7.4+	O	--without-swoole
7.4+	O	--without-swoole-coverage
7.4+	O	--without-swoole-curl
7.4+	O	--without-swoole-dev
7.4+	O	--without-swoole-json
7.4+	O	--without-system-fastlz
7.4+	O	--without-thread-context
7.4+	O	--without-trace-log
7.4+	O	--without-webp
7.4+	O	--without-xpm
7.4+	O	--without-zstd
7.4+	V	MYSQL_SOCK	/tmp/mysql.sock	MYSQLI PDO_MYSQL	MySQL socket	--with-mysql-sock=%V	default of mysqli.default_socket and pdo_mysql.default_socket; empty: none (mysqlnd uses /tmp/mysql.sock)
8.1+	I	core	007	ZTS	0	--enable-zts	-	Force Zend Thread Safety (ZTS) build	for Apache with the event or worker MPM; slower
8.1+	I	core	012	JIT	1	-	--disable-opcache-jit	OPcache JIT	compiled in by default; turned on in php.ini (opcache.jit, opcache.jit_buffer_size)
8.1-8.3	I	ext	000	ARGON2	0	--with-password-argon2	-	Argon2 in password_hash()	package libargon2
8.1+	I	gdformats	003	GD.F_AVIF	0	--with-avif	-	AVIF image format support	package libavif
8.1+	I	swoole	003	SWOOLE.PGSQL	0	--enable-swoole-pgsql	-	Coroutine PostgreSQL client	PostgreSQL client package
8.1+	I	swoole	004	SWOOLE.SQLITE	0	--enable-swoole-sqlite	-	Coroutine SQLite (PDO)	package sqlite3
8.1+	I	swoole	005	SWOOLE.ODBC	0	--with-swoole-odbc=unixODBC,/usr/local	-	Coroutine ODBC (PDO)	package unixODBC
8.1-8.3	R	PDO_DBLIB	PDO	ext/pdo_dblib/config.m4:54 PHP_ADD_EXTENSION_DEP, ext/pdo_dblib/config.m4:9 AC_MSG_ERROR, ext/pdo_dblib/pdo_dblib.c:35 ZEND_MOD_REQUIRED
8.1-8.3	R	PDO_FIREBIRD	PDO	ext/pdo_firebird/config.m4:10 AC_MSG_ERROR, ext/pdo_firebird/config.m4:66 PHP_ADD_EXTENSION_DEP, ext/pdo_firebird/pdo_firebird.c:31 ZEND_MOD_REQUIRED
8.1-8.3	R	PDO_MYSQL	PDO	ext/pdo_mysql/config.m4:104 PHP_ADD_EXTENSION_DEP, ext/pdo_mysql/config.m4:31 AC_MSG_ERROR, ext/pdo_mysql/pdo_mysql.c:219 ZEND_MOD_REQUIRED
8.1-8.2	R	PDO_ODBC	PDO	ext/pdo_odbc/config.m4:143 PHP_ADD_EXTENSION_DEP, ext/pdo_odbc/config.m4:29 AC_MSG_ERROR, ext/pdo_odbc/pdo_odbc.c:31 ZEND_MOD_REQUIRED
8.1-8.3	R	PDO_PGSQL	PDO	ext/pdo_pgsql/config.m4:10 AC_MSG_ERROR, ext/pdo_pgsql/config.m4:82 PHP_ADD_EXTENSION_DEP, ext/pdo_pgsql/pdo_pgsql.c:31 ZEND_MOD_REQUIRED
8.1-8.3	R	PDO_SQLITE	PDO	ext/pdo_sqlite/config.m4:10 AC_MSG_ERROR, ext/pdo_sqlite/config.m4:33 PHP_ADD_EXTENSION_DEP, ext/pdo_sqlite/pdo_sqlite.c:32 ZEND_MOD_REQUIRED
8.1+	R	SWOOLE.ODBC	PDO	PDO driver
8.1+	R	SWOOLE.PGSQL	PDO	PDO driver
8.1+	R	SWOOLE.SQLITE	PDO	PDO driver
8.1	R	XMLREADER	LIBXML	ext/xmlreader/config.m4:10 AC_MSG_ERROR, ext/xmlreader/php_xmlreader.c:305 ZEND_MOD_REQUIRED
8.1-8.3	R	XSL	LIBXML	ext/xsl/config.m4:31 PHP_ADD_EXTENSION_DEP, ext/xsl/config.m4:9 AC_MSG_ERROR, ext/xsl/php_xsl.c:31 ZEND_MOD_REQUIRED
8.1+	O	--disable-avif
8.1+	O	--disable-external-libcrypt
8.1+	O	--disable-fpm-apparmor
8.1+	O	--disable-iouring
8.1+	O	--disable-nghttp2-dir
8.1+	O	--disable-swoole-coro-time
8.1+	O	--disable-swoole-odbc
8.1+	O	--disable-swoole-oracle
8.1+	O	--disable-swoole-pgsql
8.1+	O	--disable-swoole-sqlite
8.1+	O	--disable-swoole-stdext
8.1+	O	--disable-swoole-thread
8.1+	O	--enable-avif
8.1+	O	--enable-external-libcrypt
8.1+	O	--enable-fpm-apparmor
8.1+	O	--enable-iouring
8.1+	O	--enable-nghttp2-dir
8.1+	O	--enable-swoole-coro-time
8.1+	O	--enable-swoole-odbc
8.1+	O	--enable-swoole-oracle
8.1+	O	--enable-swoole-pgsql
8.1+	O	--enable-swoole-sqlite
8.1+	O	--enable-swoole-stdext
8.1+	O	--enable-swoole-thread
8.1+	O	--with-avif
8.1+	O	--with-external-libcrypt
8.1+	O	--with-fpm-apparmor
8.1+	O	--with-iouring
8.1+	O	--with-nghttp2-dir
8.1+	O	--with-opcache-jit
8.1+	O	--with-swoole-coro-time
8.1+	O	--with-swoole-odbc
8.1+	O	--with-swoole-oracle
8.1+	O	--with-swoole-pgsql
8.1+	O	--with-swoole-sqlite
8.1+	O	--with-swoole-stdext
8.1+	O	--with-swoole-thread
8.1+	O	--with-zts
8.1+	O	--without-avif
8.1+	O	--without-external-libcrypt
8.1+	O	--without-fpm-apparmor
8.1+	O	--without-iouring
8.1+	O	--without-nghttp2-dir
8.1+	O	--without-opcache-jit
8.1+	O	--without-swoole-coro-time
8.1+	O	--without-swoole-odbc
8.1+	O	--without-swoole-oracle
8.1+	O	--without-swoole-pgsql
8.1+	O	--without-swoole-sqlite
8.1+	O	--without-swoole-stdext
8.1+	O	--without-swoole-thread
8.1+	O	--without-zts
8.2+	I	swoole	006	SWOOLE.FIREBIRD	0	--with-swoole-firebird	-	Coroutine Firebird (PDO)	Firebird client package
8.2+	I	swoole	007	SWOOLE.SSH2	0	--with-swoole-ssh2	-	Enable SSH2 support	package libssh2
8.2+	R	SWOOLE.FIREBIRD	PDO	PDO driver
8.2	R	XMLREADER	LIBXML	ext/xmlreader/config.m4:10 AC_MSG_ERROR, ext/xmlreader/php_xmlreader.c:304 ZEND_MOD_REQUIRED
8.2+	O	--disable-fpm-selinux
8.2+	O	--disable-liburing-dir
8.2+	O	--disable-swoole-firebird
8.2+	O	--disable-swoole-ftp
8.2+	O	--disable-swoole-ssh2
8.2+	O	--disable-uring-socket
8.2+	O	--enable-fpm-selinux
8.2+	O	--enable-liburing-dir
8.2+	O	--enable-swoole-firebird
8.2+	O	--enable-swoole-ftp
8.2+	O	--enable-swoole-ssh2
8.2+	O	--enable-uring-socket
8.2+	O	--with-fpm-selinux
8.2+	O	--with-liburing-dir
8.2+	O	--with-swoole-firebird
8.2+	O	--with-swoole-ftp
8.2+	O	--with-swoole-ssh2
8.2+	O	--with-uring-socket
8.2+	O	--without-fpm-selinux
8.2+	O	--without-liburing-dir
8.2+	O	--without-swoole-firebird
8.2+	O	--without-swoole-ftp
8.2+	O	--without-swoole-ssh2
8.2+	O	--without-uring-socket
8.3	R	PDO_ODBC	PDO	ext/pdo_odbc/config.m4:143 PHP_ADD_EXTENSION_DEP, ext/pdo_odbc/config.m4:29 AC_MSG_ERROR, ext/pdo_odbc/pdo_odbc.c:32 ZEND_MOD_REQUIRED
8.3	R	XMLREADER	LIBXML	ext/xmlreader/config.m4:10 AC_MSG_ERROR, ext/xmlreader/php_xmlreader.c:306 ZEND_MOD_REQUIRED
8.3+	O	--disable-capstone
8.3+	O	--enable-capstone
8.3+	O	--with-capstone
8.3+	O	--without-capstone
8.4	S	002	argon2	radio	ARGON2	-	Argon2: which implementation
8.4	S	005	ftp	check	FTP	-	FTP options
8.4	I	ext	000	ARGON2	0	-	-	Argon2 in password_hash()	libargon2 or OpenSSL 3.2: next screen
8.4	I	argon2	000	ARGON2.LIBARGON2	1	--with-password-argon2	-	libargon2 (security/libargon2)	package libargon2; works with ZTS
8.4	I	argon2	001	ARGON2.OPENSSL	0	--with-openssl-argon2	-	OpenSSL 3.2 and later (FreeBSD 15 base)	no libargon2; not with ZTS; adds openssl_password_hash(); as the ports on FreeBSD 15
8.4	I	ftp	000	FTP.SSL	0	--with-ftp-ssl	-	FTP over SSL without the openssl extension	with OPENSSL on, ftp_ssl_connect is there anyway (ext/ftp/config.m4)
8.4	R	ARGON2.OPENSSL	OPENSSL	it is part of the openssl extension
8.4	R	DOM	LIBXML	ext/dom/config.m4:261 PHP_ADD_EXTENSION_DEP
8.4	R	PDO_DBLIB	PDO	ext/pdo_dblib/config.m4:44 PHP_ADD_EXTENSION_DEP, ext/pdo_dblib/pdo_dblib.c:38 ZEND_MOD_REQUIRED
8.4	R	PDO_FIREBIRD	PDO	ext/pdo_firebird/config.m4:48 PHP_ADD_EXTENSION_DEP, ext/pdo_firebird/pdo_firebird.c:34 ZEND_MOD_REQUIRED
8.4	R	PDO_MYSQL	PDO	ext/pdo_mysql/config.m4:86 PHP_ADD_EXTENSION_DEP, ext/pdo_mysql/pdo_mysql.c:243 ZEND_MOD_REQUIRED
8.4	R	PDO_ODBC	PDO	ext/pdo_odbc/config.m4:132 PHP_ADD_EXTENSION_DEP, ext/pdo_odbc/pdo_odbc.c:34 ZEND_MOD_REQUIRED
8.4	R	PDO_PGSQL	PDO	ext/pdo_pgsql/config.m4:39 PHP_ADD_EXTENSION_DEP, ext/pdo_pgsql/pdo_pgsql.c:35 ZEND_MOD_REQUIRED
8.4	R	PDO_SQLITE	PDO	ext/pdo_sqlite/config.m4:40 PHP_ADD_EXTENSION_DEP, ext/pdo_sqlite/pdo_sqlite.c:36 ZEND_MOD_REQUIRED
8.4	R	SIMPLEXML	LIBXML	ext/simplexml/config.m4:12 PHP_ADD_EXTENSION_DEP
8.4	R	SOAP	LIBXML	ext/soap/config.m4:25 PHP_ADD_EXTENSION_DEP, ext/soap/soap.c:315 ZEND_MOD_REQUIRED
8.4	R	XML	LIBXML	ext/xml/config.m4:26 PHP_ADD_EXTENSION_DEP
8.4	R	XMLREADER	LIBXML	ext/xmlreader/config.m4:13 PHP_ADD_EXTENSION_DEP, ext/xmlreader/php_xmlreader.c:352 ZEND_MOD_REQUIRED
8.4	R	XMLWRITER	LIBXML	ext/xmlwriter/config.m4:12 PHP_ADD_EXTENSION_DEP, ext/xmlwriter/php_xmlwriter.c:194 ZEND_MOD_REQUIRED
8.4	R	XSL	LIBXML	ext/xsl/config.m4:24 PHP_ADD_EXTENSION_DEP, ext/xsl/php_xsl.c:30 ZEND_MOD_REQUIRED
8.4	X	ZTS	ARGON2.OPENSSL	ext/openssl/config0.m4: "Not supported in ZTS mode for now"
8.4	D	ARGON2.OPENSSL	ossl32
8.4	D	ARGON2.LIBARGON2	!ossl32
8.4	O	--disable-ftp-ssl
8.4	O	--disable-mysqlnd-ssl
8.4	O	--disable-openssl-argon2
8.4	O	--enable-ftp-ssl
8.4	O	--enable-mysqlnd-ssl
8.4	O	--enable-openssl-argon2
8.4	O	--with-ftp-ssl
8.4	O	--with-mysqlnd-ssl
8.4	O	--without-ftp-ssl
8.4	O	--without-mysqlnd-ssl
8.4	O	--without-openssl-argon2
EOF
}
# --- end of data ---

# --- arguments ----------------------------------------------------------------------
branch="" batch="" reset="" list="" changes="" values=""
for a in "$@"; do
    case "$a" in
        -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
        --batch) batch=1 ;;
        --reset) reset=1 ;;
        --list) list=1 ;;
        [0-9].[0-9]) branch="$a" ;;
        [+-][A-Z]*) changes="$changes $a" ;;
        [A-Z]*=*) values="$values$a
" ;;
        *) die "unknown argument: $a (sh php-menu.sh --help)" ;;
    esac
done
[ -z "$changes$values" ] || [ -n "$batch" ] || die "+ID, -ID and ID=value are for --batch"

if [ -z "$branch" ] && [ -f main/php_version.h ]; then
    branch="$(awk '$2 == "PHP_MAJOR_VERSION" { a = $3 } $2 == "PHP_MINOR_VERSION" { b = $3 }
        END { if (a != "") print a "." b }' main/php_version.h)"
fi

if [ -z "$batch" ] && [ -z "$list" ]; then
    DIALOG="${DIALOG:-$(command -v bsddialog || command -v dialog)}"
    [ -n "$DIALOG" ] || die "neither bsddialog nor dialog found (FreeBSD 13: dialog is in the base system)"
    [ -t 0 ] || die "the menu needs a terminal (or use --batch)"
fi
# the answer of the dialog comes on stderr, the dialog itself goes to the terminal
# shellcheck disable=SC2069
dlg() { "$DIALOG" --backtitle "$backtitle" "$@" 2>&1 >/dev/tty; }

if [ -z "$branch" ]; then
    [ -z "$batch" ] && [ -z "$list" ] || die "not in a PHP source tree: name the branch (sh php-menu.sh 8.4)"
    backtitle="php-menu: azsupport/php-src"
    set --
    for b in $BRANCHES; do set -- "$@" "$b" "PHP $b"; done
    branch="$(dlg --title "PHP branch" --menu "Not in a PHP source tree. Which branch?" 0 0 0 "$@")" || exit 1
fi
case " $BRANCHES " in
    *" $branch "*) ;;
    *) die "PHP $branch is no branch of this fork ($BRANCHES)" ;;
esac
short="$(echo "$branch" | tr -d .)"
backtitle="php-menu: PHP $branch (azsupport/php-src), choices: $db/php$short.options"

tmp="$(mktemp -d)" || exit 2
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' INT TERM HUP

# --- the data of this branch ------------------------------------------------------
# screens: order id kind parent show-if title
# items:   screen-order item-order screen id default on off description help
# rels:    R|X item other why;  dyn: item rule;  defon: item;  owned: option
# vals_def: value default when description arguments help
menu_data | awk -F '\t' -v b="$branch" -v d="$tmp" '
    function v(x,   p) { split(x, p, "."); return p[1] * 100 + p[2] }
    function inspan(s,   p) {
        if (s == "*" || s == b) return 1
        if (s ~ /\+$/) return v(b) >= v(substr(s, 1, length(s) - 1))
        if (index(s, "-")) { split(s, p, "-"); return v(b) >= v(p[1]) && v(b) <= v(p[2]) }
        return 0
    }
    !inspan($1) { next }
    $2 == "S" { so[$4] = $3; t = $8; gsub(/%B/, b, t)
                print $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 "\t" t > (d "/screens.u") }
    $2 == "I" { n++; il[n] = $0 }
    $2 == "R" || $2 == "X" { print $2 "\t" $3 "\t" $4 "\t" $5 > (d "/rels") }
    $2 == "D" { print $3 "\t" $4 > (d "/dyn") }
    $2 == "E" { print $3 > (d "/defon") }
    $2 == "O" { print $3 > (d "/owned") }
    $2 == "V" { print $3 "\t" $4 "\t" $5 "\t" $6 "\t" $7 "\t" $8 > (d "/vals_def") }
    END {
        for (i = 1; i <= n; i++) {
            split(il[i], f, "\t")
            print so[f[3]] "\t" f[4] "\t" f[3] "\t" f[5] "\t" f[6] "\t" f[7] "\t" f[8] "\t" f[9] "\t" f[10] > (d "/items.u")
        }
    }'
for f in rels dyn defon owned vals_def; do [ -f "$tmp/$f" ] || : > "$tmp/$f"; done
sort -t "$TAB" -k1,1 "$tmp/screens.u" > "$tmp/screens"
sort -t "$TAB" -k1,1 -k2,2 "$tmp/items.u" > "$tmp/items"
[ -s "$tmp/items" ] || die "no menu data for PHP $branch"

# --- the state: the items that are on, " A B C " ---------------------------------------
# The engine (one awk run) answers from the data and the state: an item counts
# ("active") when it is on, its parent counts (REDIS for REDIS.LZ4) and the
# show-if of its screen holds (GD.EXTERNAL=0 for the formats of the libgd of PHP).
ON=" "
is_on() { case "$ON" in *" $1 "*) return 0 ;; esac; return 1; }
set_on() { is_on "$1" || ON="$ON$1 "; }
set_off() { case "$ON" in *" $1 "*) ON="${ON%%" $1 "*} ${ON#*" $1 "}" ;; esac; }

engine() {
    awk -F '\t' -v mode="$1" -v on="$ON" -v d="$tmp" '
    function parent(id,   p) { p = id; if (index(p, ".")) { sub(/\..*/, "", p); return p } return "" }
    function act(id,   p, c, x) {
        if (!(id in st)) return 0
        p = parent(id)
        if (p != "" && !act(p)) return 0
        c = sshow[scr[id]]
        if (c ~ /=0$/) { x = c; sub(/=0$/, "", x); if (x in st) return 0 }
        if (c ~ /=1$/) { x = c; sub(/=1$/, "", x); if (!(x in st)) return 0 }
        return 1
    }
    function shown(id,   s) {
        if (!index(id, ".")) return id
        s = id; sub(/^[^.]*\./, "", s); sub(/^F_/, "", s)
        return parent(id) " " s
    }
    function onset(   s, i) { s = " "; for (i = 1; i <= n; i++) if (ids[i] in st) s = s ids[i] " "; return s }
    BEGIN {
        while ((getline l < (d "/screens")) > 0) {
            split(l, f, "\t"); sn++; sids[sn] = f[2]; skind[f[2]] = f[3]; sparent[f[2]] = f[4]; sshow[f[2]] = f[5]
        }
        while ((getline l < (d "/items")) > 0) {
            split(l, f, "\t"); n++; ids[n] = f[4]; scr[f[4]] = f[3]; desc[f[4]] = f[8]; help[f[4]] = f[9]
            onv[f[4]] = (f[6] == "-" ? "" : f[6]); offv[f[4]] = (f[7] == "-" ? "" : f[7])
        }
        while ((getline l < (d "/rels")) > 0) { split(l, f, "\t"); r++; rk[r] = f[1]; ra[r] = f[2]; ro[r] = f[3]; rw[r] = f[4] }
        k = split(on, w, " ")
        for (i = 1; i <= k; i++) st[w[i]] = 1

        if (mode == "radios") {         # exactly one item on in every radio screen
            for (s = 1; s <= sn; s++) {
                if (skind[sids[s]] != "radio") continue
                first = ""; cnt = 0
                for (i = 1; i <= n; i++) {
                    if (scr[ids[i]] != sids[s]) continue
                    if (first == "") first = ids[i]
                    if (ids[i] in st) { if (++cnt > 1) delete st[ids[i]] }
                }
                if (!cnt && first != "") st[first] = 1
            }
            print onset()
        } else if (mode == "closure") {   # turn on what the active items need
            for (pass = 0; pass < 20; pass++) {
                ch = 0
                for (i = 1; i <= r; i++)
                    if (rk[i] == "R" && act(ra[i]) && !(ro[i] in st)) {
                        st[ro[i]] = 1; ch = 1
                        print "MSG\t" shown(ro[i]) " turned on: " shown(ra[i]) " needs it (" rw[i] ")"
                    }
                if (!ch) break
            }
            print "ON\t" onset()
        } else if (mode == "conflicts") {
            for (i = 1; i <= r; i++)
                if (rk[i] == "X" && act(ra[i]) && act(ro[i]) && !((ro[i] SUBSEP ra[i]) in seen)) {
                    seen[ra[i] SUBSEP ro[i]] = 1
                    print shown(ra[i]) " and " shown(ro[i]) " cannot go together (" rw[i] ")"
                }
        } else if (mode == "options") {  # the configure options of the choices
            for (i = 1; i <= n; i++) {
                id = ids[i]; p = parent(id)
                if (p != "" && !act(p)) continue
                c = sshow[scr[id]]
                if (c ~ /=0$/) { x = c; sub(/=0$/, "", x); if (x in st) continue }
                if (c ~ /=1$/) { x = c; sub(/=1$/, "", x); if (!(x in st)) continue }
                a = (id in st) ? onv[id] : offv[id]
                k = split(a, w, " ")
                for (j = 1; j <= k; j++) print w[j]
            }
        } else if (mode ~ /^visible /) {  # does a screen of options show now
            s = mode; sub(/^visible /, "", s)
            ok = (sparent[s] == "-" || act(sparent[s]))
            c = sshow[s]
            if (c ~ /=0$/) { x = c; sub(/=0$/, "", x); if (x in st) ok = 0 }
            if (c ~ /=1$/) { x = c; sub(/=1$/, "", x); if (!(x in st)) ok = 0 }
            print ok ? 1 : 0
        } else if (mode ~ /^active /) {   # is one of these items active
            s = mode; sub(/^active /, "", s); k = split(s, w, " "); ok = 0
            for (j = 1; j <= k; j++) if (act(w[j])) ok = 1
            print ok
        } else if (mode == "list") {
            for (i = 1; i <= n; i++) printf "%-10s %-20s %-3s %s\n", scr[ids[i]], ids[i], (act(ids[i]) ? "on" : "off"), desc[ids[i]]
        } else if (mode == "packages") { # what the help of the active items names as "package foo"
            for (i = 1; i <= n; i++) {
                if (!act(ids[i])) continue
                k = split(help[ids[i]], w, " ")
                for (j = 1; j < k; j++) {
                    x = w[j]; sub(/^\(/, "", x)
                    if (x != "package" && x != "packages") continue
                    one = (x == "package")
                    for (m = j + 1; m <= k; m++) {
                        x = w[m]; last = (x ~ /[;:,.)]$/); sub(/[;:,.)]+$/, "", x)
                        if (x !~ /^[A-Za-z0-9_+-][A-Za-z0-9_.+-]*$/) break
                        pk[x] = 1
                        if (last || one) break
                    }
                }
            }
            for (x in pk) print x
        } else if (mode == "help") {     # the dialog lines: screen, tag, description, help
            for (i = 1; i <= r; i++) {
                if (rk[i] == "R") needs[ra[i]] = needs[ra[i]] (needs[ra[i]] == "" ? "" : ", ") shown(ro[i])
                if (rk[i] == "X") excl[ra[i]] = excl[ra[i]] (excl[ra[i]] == "" ? "" : ", ") shown(ro[i])
            }
            for (i = 1; i <= n; i++) {
                id = ids[i]; tag = id
                if (index(tag, ".")) { sub(/^[^.]*\./, "", tag); sub(/^F_/, "", tag) }
                h = (help[id] == "-" ? "" : help[id])
                if (needs[id] != "") h = h (h == "" ? "" : "; ") "needs " needs[id]
                if (excl[id] != "") h = h (h == "" ? "" : "; ") "not with " excl[id]
                print scr[id] "\t" id "\t" tag "\t" desc[id] "\t" (h == "" ? " " : h)
            }
        }
    }'
}
fix_radios() { ON="$(engine radios)"; }
closure() { engine closure > "$tmp/cl"; ON="$(sed -n "s/^ON$TAB//p" "$tmp/cl")"; msgs="$(sed -n "s/^MSG$TAB//p" "$tmp/cl")"; }
conflicts() { bad="$(engine conflicts)"; }
chosen_options() { engine options; }

# --- the values typed in (PREFIX, MYSQL_SOCK): "$tmp/vals", value TAB text -----------
: > "$tmp/vals"
val_get() { awk -F '\t' -v id="$1" '$1 == id { v = $2 } END { printf "%s", v }' "$tmp/vals"; }
val_set() {
    awk -F '\t' -v id="$1" '$1 != id' "$tmp/vals" > "$tmp/vals.n"
    printf '%s\t%s\n' "$1" "$2" >> "$tmp/vals.n"
    mv "$tmp/vals.n" "$tmp/vals"
}
val_known() { awk -F '\t' -v id="$1" '$1 == id { f = 1 } END { exit !f }' "$tmp/vals_def"; }
val_field() { awk -F '\t' -v id="$1" -v n="$2" '$1 == id { print $n; exit }' "$tmp/vals_def"; }
# a path as configure takes it: absolute, of letters, digits and . _ / + - (no
# spaces), without the slash at the end; empty only for a value that may be
# empty (the ones shown with an item); prints it, or fails
val_clean() {
    v="$2"
    while [ "${#v}" -gt 1 ] && [ "${v%/}" != "$v" ]; do v="${v%/}"; done
    case "$v" in
        '') [ "$(val_field "$1" 3)" != "-" ] || return 1 ;;
        /*) case "$v" in *[!A-Za-z0-9._/+-]*) return 1 ;; esac ;;
        *) return 1 ;;
    esac
    printf '%s' "$v"
}
# is the value used now: shown always, or one of its items is on
val_used() {
    w="$(val_field "$1" 3)"
    [ "$w" = "-" ] || [ "$(engine "active $w")" = 1 ]
}
# the configure options of the values: "top" (the ones shown always: PREFIX) or
# "rest" (the others, when one of their items is on), none for an empty value
val_options() {
    while IFS="$TAB" read -r vid _ when _ vargs _; do
        if [ "$1" = top ]; then [ "$when" = "-" ] || continue; else [ "$when" != "-" ] || continue; fi
        val_used "$vid" || continue
        v="$(val_get "$vid")"
        [ -n "$v" ] || continue
        for w in $vargs; do printf '%s\n' "$w" | sed "s|%V|$v|g"; done
    done < "$tmp/vals_def"
}
while IFS="$TAB" read -r vid vdef _; do
    val_set "$vid" "$(printf '%s' "$vdef" | sed "s/%S/$short/g")"
done < "$tmp/vals_def"

# OpenSSL of the base system (the one the build uses): major*100+minor, 0 unknown
ossl_ver() {
    h=/usr/include/openssl/opensslv.h
    if [ -f "$h" ]; then
        awk '{ sub(/^#[ \t]*define[ \t]+/, "#define ") }
             $2 == "OPENSSL_VERSION_MAJOR" { a = $3 } $2 == "OPENSSL_VERSION_MINOR" { b = $3 }
             $2 == "OPENSSL_VERSION_NUMBER" && a == "" { n = $3 }
             END { if (a != "") print a * 100 + b; else if (n ~ /^0x1/) print 101; else print 0 }' "$h"
    elif command -v openssl >/dev/null 2>&1; then
        openssl version 2>/dev/null | awk '{ split($2, p, "."); print p[1] * 100 + p[2]; exit }'
    else
        echo 0
    fi
}

# defaults of the data, then the rules decided here (OpenSSL 3, 3.2)
while IFS="$TAB" read -r _ _ _ id dflt _; do
    [ "$dflt" = 1 ] && set_on "$id"
done < "$tmp/items"
ov="$(ossl_ver)"
while IFS="$TAB" read -r id rule; do
    case "$rule" in
        ossl3) [ "$ov" -ge 300 ] ;;
        '!ossl3') [ "$ov" -lt 300 ] ;;
        ossl32) [ "$ov" -ge 302 ] ;;
        '!ossl32') [ "$ov" -lt 302 ] ;;
        *) false ;;
    esac && set_on "$id" || set_off "$id"
done < "$tmp/dyn"
start="the defaults: CLI and OPcache only"

# config.installed.sh: its environment lines and its options, one per line, unquoted
if [ -f "$installed" ]; then
    awk -v env="$tmp/inst_env" -v opt="$tmp/inst_opts" -v q="'" '
        $0 == q "./configure" q " \\" { in_opts = 1; next }
        $0 == "\"$@\"" { in_opts = 0; next }
        { line = $0; sub(/ \\$/, "", line) }
        !in_opts && line ~ /^[A-Za-z_][A-Za-z0-9_]*=/ { print line > env; next }
        in_opts { sub("^" q, "", line); sub(q "$", "", line); gsub(q "\\\\" q q, q, line); print line > opt }
    ' "$installed"
    [ -f "$tmp/inst_env" ] || : > "$tmp/inst_env"
    [ -f "$tmp/inst_opts" ] || : > "$tmp/inst_opts"
fi

# The items the installed build has: an item is on when its first option is there
# (with its value, or by name when no other item of the screen has that option; of
# items that share an option name - --with-curl=bundled and =/usr/local - with no
# exact match the last one, the system library); an item with options that turn
# it off (CGI, IPV6, sessions of redis) is on unless one of them is there; without
# --disable-all the extensions PHP builds by itself are on unless disabled.
from_installed() {
    noall=1
    grep -qx -- '--disable-all' "$tmp/inst_opts" && noall=""
    awk -F '\t' -v opts="$tmp/inst_opts" -v defon="$tmp/defon" -v noall="$noall" '
        function name(o) { sub(/=.*/, "", o); return o }
        BEGIN {
            while ((getline o < opts) > 0) { have[o] = 1; hn[name(o)] = 1 }
            while ((getline e < defon) > 0) dflt[e] = 1
        }
        {
            n++; id[n] = $4; scr[n] = $3; off[n] = ($7 == "-" ? "" : $7)
            split($6, w, " "); first[n] = ($6 == "-" ? "" : w[1])
            if (first[n] != "") { g = scr[n] SUBSEP name(first[n]); users[g]++; last[g] = n }
        }
        END {
            for (i = 1; i <= n; i++) {
                if (first[i] == "") continue
                g = scr[i] SUBSEP name(first[i])
                if (first[i] in have) { st[i] = 1; exact[g] = 1 }
                else if ((name(first[i]) in hn) && users[g] == 1) st[i] = 1
                else st[i] = 0
            }
            for (g in users) if (users[g] > 1 && !(g in exact)) {
                split(g, p, SUBSEP)
                if (p[2] in hn) st[last[g]] = 1
            }
            for (i = 1; i <= n; i++) {
                if (off[i] != "") {
                    k = split(off[i], w, " "); dis = 0
                    for (j = 1; j <= k; j++) if (name(w[j]) in hn) dis = 1
                    st[i] = dis ? 0 : 1
                }
                if (noall && (id[i] in dflt) && !st[i]) {
                    x = tolower(id[i]); gsub(/_/, "-", x)
                    if (!(("--disable-" x) in hn) && !(("--without-" x) in hn)) st[i] = 1
                }
                if (i in st) print id[i] "\t" st[i]
            }
        }' "$tmp/items"
}

# the values the installed build has (--prefix=, --with-mysql-sock=): the first
# option of a value, when it is the value alone
if [ -z "$reset" ] && [ -f "$installed" ]; then
    while IFS="$TAB" read -r vid _ _ _ vargs _; do
        w="${vargs%% *}"
        [ "${w#*=}" = "%V" ] || continue
        v="$(sed -n "s|^${w%%=*}=||p" "$tmp/inst_opts" | tail -n 1)"
        [ -n "$v" ] && v="$(val_clean "$vid" "$v")" && val_set "$vid" "$v"
    done < "$tmp/vals_def"
fi

if [ -z "$reset" ] && [ -f "$db/php$short.options" ]; then
    while IFS= read -r l; do
        case "$l" in
            OPTIONS_FILE_SET+=*) set_on "${l#OPTIONS_FILE_SET+=}" ;;
            OPTIONS_FILE_UNSET+=*) set_off "${l#OPTIONS_FILE_UNSET+=}" ;;
            VALUE_*=*)
                vid="${l#VALUE_}"; vid="${vid%%=*}"
                val_known "$vid" && v="$(val_clean "$vid" "${l#*=}")" && val_set "$vid" "$v" ;;
        esac
    done < "$db/php$short.options"
    start="the choices saved in $db/php$short.options"
elif [ -z "$reset" ] && [ -f "$installed" ]; then
    from_installed > "$tmp/inst_state"
    while IFS="$TAB" read -r id st; do
        if [ "$st" = 1 ]; then set_on "$id"; else set_off "$id"; fi
    done < "$tmp/inst_state"
    # extensions without options of their own (CURL, READLINE, ARGON2 of 8.4):
    # on when one of their items is
    while IFS="$TAB" read -r _ _ scr id _ on _; do
        [ "$scr" = ext ] && [ "$on" = "-" ] || continue
        set_off "$id"
        case "$ON" in *" $id."*) set_on "$id" ;; esac
    done < "$tmp/items"
    start="what the build of $installed has"
fi

# one screen: 0 OK, 1 cancel
show_screen() {
    sid="$1"
    kind="$(awk -F '\t' -v s="$sid" '$2 == s { print $3; exit }' "$tmp/screens")"
    title="$(awk -F '\t' -v s="$sid" '$2 == s { print $6; exit }' "$tmp/screens")"
    while :; do
        set --
        while IFS="$TAB" read -r scr id tag desc help; do
            [ "$scr" = "$sid" ] || continue
            st=off; is_on "$id" && st=on
            set -- "$@" "$tag" "$desc" "$st" "$help"
        done < "$tmp/help"
        [ $# -gt 0 ] || return 0
        if [ "$kind" = radio ]; then
            res="$(dlg --title "$title" --item-help --radiolist "Choose one. Start: $start" 0 0 0 "$@")" || return 1
        else
            res="$(dlg --title "$title" --item-help --separate-output --checklist \
                "Space turns an item on or off. Start: $start" 0 0 0 "$@")" || return 1
        fi
        sel=" $(printf '%s' "$res" | tr -d '"' | tr '\n' ' ') "
        while IFS="$TAB" read -r scr id tag desc help; do
            [ "$scr" = "$sid" ] || continue
            case "$sel" in *" $tag "*) set_on "$id" ;; *) set_off "$id" ;; esac
        done < "$tmp/help"
        fix_radios
        closure
        conflicts
        if [ -n "$bad" ]; then
            dlg --title "Not together" --msgbox "$bad

Turn one of them off." 0 0
            continue
        fi
        [ -z "$msgs" ] || dlg --title "Turned on as well" --msgbox "$msgs" 0 0
        return 0
    done
}

# make.conf: the -march of this server (CPUTYPE, else -march= of CFLAGS)
mc_get() {
    [ -r "$mk_conf" ] || return 0
    awk -v v="$1" '{ sub(/#.*/, "") }
        $0 ~ "^[ \t]*" v "[ \t]*[?:]?=" { s = $0; sub("^[ \t]*" v "[ \t]*[?:]?=[ \t]*", "", s); val = s }
        END { sub(/[ \t]+$/, "", val); print val }' "$mk_conf"
}
mc_march() {
    t="$(mc_get CPUTYPE)"
    [ -n "$t" ] || t="$(mc_get CFLAGS | tr -s ' \t' '\n\n' | sed -n 's/^-march=//p' | tail -n 1)"
    printf '%s' "$t"
}

# the script: the base (config.installed.sh, else our base build) and the choices
compose() {
    : > "$tmp/opts"
    if [ -f "$installed" ]; then
        cp "$tmp/inst_env" "$tmp/env"
        # its options the menu does not decide; the ones with a path inside its
        # install directory move to the new one (php.ini paths)
        old="$(sed -n 's/^--prefix=//p' "$tmp/inst_opts" | tail -n 1)"
        awk -v owned="$tmp/owned" -v old="$old" -v new="$(val_get PREFIX)" '
            BEGIN { while ((getline o < owned) > 0) own[o] = 1 }
            { n = $0; sub(/=.*/, "", n) }
            n in own { next }
            old != "" && new != "" && old != new && index($0, "=") {
                v = substr($0, index($0, "=") + 1)
                if (v == old || substr(v, 1, length(old) + 1) == old "/") $0 = n "=" new substr(v, length(old) + 1)
            }
            { print }' "$tmp/inst_opts" > "$tmp/opts"
        base="the other options and the environment of $installed"
    else
        m="$(mc_march)"
        cf="-O3 -pipe${m:+ -march=$m} -fstack-protector-strong -fno-strict-aliasing"
        printf "CFLAGS='%s'\nCXXFLAGS='%s'\nLIBS='-lpthread'\n" "$cf" "$cf" > "$tmp/env"
        printf '%s\n' "--build=$(uname -p)-srcbld-$(uname -s | tr 'A-Z' 'a-z')$(uname -r | sed 's/[-(].*//')" \
            "--with-layout=GNU" > "$tmp/opts"
        base="our base build (CFLAGS with the -march of $mk_conf)"
    fi
    # the install directory (and the man pages in it) after --build
    val_options top > "$tmp/vtop"
    { grep -- '^--build=' "$tmp/opts"; cat "$tmp/vtop"; grep -v -- '^--build=' "$tmp/opts"; } > "$tmp/opts.b"
    mv "$tmp/opts.b" "$tmp/opts"
    # our base, also when the installed build lacked it
    for o in --disable-all --enable-opcache; do grep -qx -- "$o" "$tmp/opts" || echo "$o" >> "$tmp/opts"; done
    case "$branch" in
        7.4|8.1|8.2) grep -q -- '^--with\(out\)\{0,1\}-valgrind' "$tmp/opts" || echo --without-valgrind >> "$tmp/opts" ;;
    esac
    chosen_options >> "$tmp/opts"
    val_options rest >> "$tmp/opts"
    awk '!seen[$0]++' "$tmp/opts" > "$tmp/opts.u"
    {
        echo "#!/bin/sh"
        echo "# Written by php-menu.sh on $(date '+%d.%m.%Y %H:%M'): PHP $branch, the choices of the menu"
        echo "# ($db/php$short.options) on $base."
        echo "# Run from inside the new PHP source tree: sh $out"
        echo
        sed 's/$/ \\/' "$tmp/env"
        echo "'./configure' \\"
        sed "s/'/'\\\\''/g; s/^/'/; s/\$/' \\\\/" "$tmp/opts.u"
        echo '"$@"'
    } > "$tmp/script"
}
write_config() {
    compose
    cp "$tmp/script" "$out" || die "cannot write $out"
    chmod +x "$out" 2>/dev/null || true
}

save_choices() {
    mkdir -p "$db" 2>/dev/null || { echo "php-menu: cannot create $db, choices not saved" >&2; return 0; }
    {
        echo "# Options of PHP $branch for php-menu.sh, written $(date '+%d.%m.%Y %H:%M')"
        echo "_OPTIONS_READ=php$short"
        while IFS="$TAB" read -r _ _ _ id _; do
            if is_on "$id"; then echo "OPTIONS_FILE_SET+=$id"; else echo "OPTIONS_FILE_UNSET+=$id"; fi
        done < "$tmp/items"
        while IFS="$TAB" read -r vid _; do echo "VALUE_$vid=$(val_get "$vid")"; done < "$tmp/vals_def"
    } > "$db/php$short.options" 2>/dev/null || echo "php-menu: cannot write $db/php$short.options" >&2
}

# packages the chosen items name in their help ("package foo")
packages() { engine packages | sort | tr '\n' ' ' | sed 's/ *$//'; }

report() {
    n="$(awk 'END { print NR }' "$tmp/opts.u")"
    echo "php-menu: wrote $out (PHP $branch, $n options), choices in $db/php$short.options"
    p="$(packages)"
    [ -n "$p" ] && echo "packages the choices name: $p"
    echo "next, in the PHP $branch source tree: sh $out && make && make install"
}

engine help > "$tmp/help"
fix_radios
if [ -n "$list" ]; then
    closure
    echo "PHP $branch, start: $start"
    engine list
    while IFS="$TAB" read -r vid _ when desc _; do
        u=""
        val_used "$vid" || u=" (not used: needs one of $when)"
        printf '%-10s %-20s %s%s\n' value "$vid" "$(val_get "$vid")" "$u"
    done < "$tmp/vals_def"
    exit 0
fi

if [ -n "$batch" ]; then
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        vid="${c%%=*}"
        val_known "$vid" || die "PHP $branch has no value $vid (sh php-menu.sh $branch --list)"
        v="$(val_clean "$vid" "${c#*=}")" || die "$vid: not a path for configure: ${c#*=}"
        val_set "$vid" "$v"
    done <<EOF
$values
EOF
    for c in $changes; do
        id="${c#?}"
        scr="$(awk -F '\t' -v id="$id" '$4 == id { print $3; exit }' "$tmp/items")"
        [ -n "$scr" ] || die "PHP $branch has no item $id (sh php-menu.sh $branch --list)"
        case "$c" in
            +*) # in a radio screen the item replaces the one that was on
                if [ "$(awk -F '\t' -v s="$scr" '$2 == s { print $3; exit }' "$tmp/screens")" = radio ]; then
                    for o in $(awk -F '\t' -v s="$scr" '$3 == s { print $4 }' "$tmp/items"); do set_off "$o"; done
                fi
                set_on "$id" ;;
            -*) set_off "$id" ;;
        esac
    done
    fix_radios
    closure
    [ -n "$msgs" ] && printf '%s\n' "$msgs" | sed 's/^/php-menu: /' >&2
    conflicts
    if [ -n "$bad" ]; then printf '%s\n' "$bad" | sed 's/^/php-menu: /' >&2; exit 1; fi
    write_config
    save_choices
    report
    exit 0
fi

# the screens in order, then a menu to go back to any of them; a screen of
# options shows when its extension is on (and its show-if holds), decided again
# before each one, since the screen before can change it
sub_screens() {
    awk -F '\t' '$4 != "-" { print $2 }' "$tmp/screens" > "$tmp/subs"
    while IFS= read -r sid; do
        [ "$(engine "visible $sid")" = 1 ] || continue
        show_screen "$sid" < /dev/tty || return 1
    done < "$tmp/subs"
}
# a value in an input box; Cancel keeps it as it was
edit_value() {
    vid="$1"
    v="$(val_get "$vid")"
    while :; do
        nv="$(dlg --title "$(val_field "$vid" 4)" --inputbox "$(val_field "$vid" 6)" 0 72 "$v")" || return 0
        if c="$(val_clean "$vid" "$nv")"; then val_set "$vid" "$c"; return 0; fi
        dlg --title "$(val_field "$vid" 4)" --msgbox "Not a path for configure: $nv

An absolute path of letters, digits and . _ / + - (no spaces)." 0 0
        v="$nv"
    done
}

show_screen core && show_screen ext && sub_screens || { echo "php-menu: cancelled, nothing written" >&2; exit 1; }
while :; do
    set -- WRITE "Write ${out##*/} and save the choices" \
        CORE "Build options" \
        EXT "Extensions" \
        OPTIONS "Options of the extensions"
    while IFS="$TAB" read -r vid _ _ desc _; do
        val_used "$vid" || continue
        v="$(val_get "$vid")"
        set -- "$@" "$vid" "$desc: ${v:-none}"
    done < "$tmp/vals_def"
    set -- "$@" SHOW "Show the script it writes" QUIT "Quit without writing"
    choice="$(dlg --title "PHP $branch" --default-item WRITE --menu \
        "Write the configure script, go back to a screen, or change a path" 0 0 0 "$@")" || choice=QUIT
    case "$choice" in
        WRITE)
            fix_radios
            closure
            conflicts
            if [ -n "$bad" ]; then dlg --title "Not together" --msgbox "$bad" 0 0; continue; fi
            write_config
            save_choices
            command -v clear >/dev/null 2>&1 && clear
            report
            exit 0 ;;
        CORE) show_screen core ;;
        EXT) show_screen ext ;;
        OPTIONS) sub_screens ;;
        SHOW) compose; dlg --title "$out" --textbox "$tmp/script" 0 0 ;;
        QUIT) command -v clear >/dev/null 2>&1 && clear; echo "php-menu: nothing written" >&2; exit 1 ;;
        *) val_known "$choice" && edit_value "$choice" ;;
    esac
done
