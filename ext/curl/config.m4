dnl
dnl $Id$ 
dnl

PHP_ARG_WITH(curl, for cURL support,
[  --with-curl[=DIR]         Include cURL support (=bundled: ext/curl/libcurl, built into PHP)])

if test "$PHP_CURL" != "no"; then
  dnl azsupport: --with-curl=bundled builds ext/curl/libcurl (the curl release,
  dnl static and position independent, with the OpenSSL of this PHP build) with
  dnl ext/curl/build-libcurl.sh and links it into PHP instead of a system libcurl.
  dnl Its curl_* symbols are not exported, so a libcurl.so that another module
  dnl loads into the same process stays separate.
  if test "$PHP_CURL" = "bundled"; then
    php_curl_bundled="$abs_builddir/ext/curl/libcurl-build"
    mkdir -p "$abs_builddir/ext/curl"
    AC_MSG_CHECKING([for the bundled libcurl])
    if env CC="$CC" CFLAGS="$CFLAGS" CPPFLAGS="$CPPFLAGS" LDFLAGS="$LDFLAGS" \
        PKG_CONFIG="${PKG_CONFIG:-pkg-config}" \
        OPENSSL_INCDIR="${OPENSSL_INCDIR:-}" OPENSSL_CFLAGS="${OPENSSL_CFLAGS:-}" \
        $SHELL "$abs_srcdir/ext/curl/build-libcurl.sh" "$php_curl_bundled" \
        > "$php_curl_bundled.log" 2>&1; then
      php_curl_bundled_version=`cat "$php_curl_bundled/VERSION"`
      AC_MSG_RESULT([curl $php_curl_bundled_version, static, in ext/curl/libcurl-build])
    else
      AC_MSG_RESULT([failed])
      tail -n 15 "$php_curl_bundled.log"
      AC_MSG_ERROR([the bundled libcurl did not build, see $php_curl_bundled.log])
    fi
    PKG_CONFIG_PATH="$php_curl_bundled/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    export PKG_CONFIG_PATH
    dnl The -L goes first, before /usr/local/lib with the libcurl.so of pkg, and
    dnl into EXTRA_LDFLAGS too: PHP 5.6 drops the LDFLAGS of the extensions. No
    dnl PHP_ADD_LIBPATH, which would record a run path into the build tree.
    LDFLAGS="-L$php_curl_bundled/lib $LDFLAGS"
    EXTRA_LDFLAGS="-L$php_curl_bundled/lib $EXTRA_LDFLAGS"
    EXTRA_LDFLAGS_PROGRAM="-L$php_curl_bundled/lib $EXTRA_LDFLAGS_PROGRAM"
    php_curl_ldflags=$LDFLAGS
    LDFLAGS="$LDFLAGS -Wl,--exclude-libs,libcurl.a"
    AC_LINK_IFELSE([AC_LANG_PROGRAM()],
      [EXTRA_LDFLAGS="$EXTRA_LDFLAGS -Wl,--exclude-libs,libcurl.a"
      EXTRA_LDFLAGS_PROGRAM="$EXTRA_LDFLAGS_PROGRAM -Wl,--exclude-libs,libcurl.a"],
      [LDFLAGS=$php_curl_ldflags])
    PHP_CURL="$php_curl_bundled"
  fi
  if test -r $PHP_CURL/include/curl/easy.h; then
    CURL_DIR=$PHP_CURL
  else
    AC_MSG_CHECKING(for cURL in default path)
    for i in /usr/local /usr; do
      if test -r $i/include/curl/easy.h; then
        CURL_DIR=$i
        AC_MSG_RESULT(found in $i)
        break
      fi
    done
  fi

  if test -z "$CURL_DIR"; then
    AC_MSG_RESULT(not found)
    AC_MSG_ERROR(Please reinstall the libcurl distribution -
    easy.h should be in <curl-dir>/include/curl/)
  fi

  CURL_CONFIG="curl-config"
  AC_MSG_CHECKING(for cURL 7.10.5 or greater)

  if ${CURL_DIR}/bin/curl-config --libs > /dev/null 2>&1; then
    CURL_CONFIG=${CURL_DIR}/bin/curl-config
  else
    if ${CURL_DIR}/curl-config --libs > /dev/null 2>&1; then
      CURL_CONFIG=${CURL_DIR}/curl-config
    fi
  fi

  curl_version_full=`$CURL_CONFIG --version`
  curl_version=`echo ${curl_version_full} | sed -e 's/libcurl //' | $AWK 'BEGIN { FS = "."; } { printf "%d", ($1 * 1000 + $2) * 1000 + $3;}'`
  if test "$curl_version" -ge 7010005; then
    AC_MSG_RESULT($curl_version_full)
    CURL_LIBS=`$CURL_CONFIG --libs`
  else
    AC_MSG_ERROR(cURL version 7.10.5 or later is required to compile php with cURL support)
  fi

  PHP_ADD_INCLUDE($CURL_DIR/include)
  PHP_EVAL_LIBLINE($CURL_LIBS, CURL_SHARED_LIBADD)
  if test "$PHP_CURL" = "$php_curl_bundled"; then
    PHP_ADD_LIBRARY(curl,, CURL_SHARED_LIBADD)
  else
    PHP_ADD_LIBRARY_WITH_PATH(curl, $CURL_DIR/$PHP_LIBDIR, CURL_SHARED_LIBADD)
  fi
  
  AC_MSG_CHECKING([for SSL support in libcurl])
  CURL_SSL=`$CURL_CONFIG --feature | $EGREP SSL`
  if test "$CURL_SSL" = "SSL"; then
    AC_MSG_RESULT([yes])
    AC_DEFINE([HAVE_CURL_SSL], [1], [Have cURL with  SSL support])
   
    save_CFLAGS="$CFLAGS"
    CFLAGS="`$CURL_CONFIG --cflags`"
   
    AC_PROG_CPP
    AC_MSG_CHECKING([for openssl support in libcurl])
    AC_TRY_RUN([
#include <curl/curl.h>
#include <strings.h>

int main(int argc, char *argv[])
{
  curl_version_info_data *data = curl_version_info(CURLVERSION_NOW);

  if (data && data->ssl_version && *data->ssl_version) {
    const char *ptr = data->ssl_version;

    while(*ptr == ' ') ++ptr;
    return strncasecmp(ptr, "OpenSSL", sizeof("OpenSSL")-1);
  }
  return 1;
}
    ],[
      AC_MSG_RESULT([yes])
      AC_CHECK_HEADERS([openssl/crypto.h], [
        AC_DEFINE([HAVE_CURL_OPENSSL], [1], [Have cURL with OpenSSL support])
      ])
    ], [
      AC_MSG_RESULT([no])
    ], [
      AC_MSG_RESULT([no])
    ])
   
    AC_MSG_CHECKING([for gnutls support in libcurl])
    AC_TRY_RUN([
#include <curl/curl.h>
#include <strings.h>

int main(int argc, char *argv[])
{
  curl_version_info_data *data = curl_version_info(CURLVERSION_NOW);
  
  if (data && data->ssl_version && *data->ssl_version) {
    const char *ptr = data->ssl_version;

    while(*ptr == ' ') ++ptr;
    return strncasecmp(ptr, "GnuTLS", sizeof("GnuTLS")-1);
  }
  return 1;
}
], [
      AC_MSG_RESULT([yes])
      AC_CHECK_HEADER([gcrypt.h], [
        AC_DEFINE([HAVE_CURL_GNUTLS], [1], [Have cURL with GnuTLS support])
      ])
    ], [
      AC_MSG_RESULT([no])
    ], [
      AC_MSG_RESULT([no])
    ])
   
    CFLAGS="$save_CFLAGS"
  else
    AC_MSG_RESULT([no])
  fi

  PHP_CHECK_LIBRARY(curl,curl_easy_perform, 
  [ 
    AC_DEFINE(HAVE_CURL,1,[ ])
  ],[
    AC_MSG_ERROR(There is something wrong. Please check config.log for more information.)
  ],[
    $CURL_LIBS -L$CURL_DIR/$PHP_LIBDIR
  ])

  PHP_CHECK_LIBRARY(curl,curl_easy_strerror,
  [
    AC_DEFINE(HAVE_CURL_EASY_STRERROR,1,[ ])
  ],[],[
    $CURL_LIBS -L$CURL_DIR/$PHP_LIBDIR
  ])

  PHP_CHECK_LIBRARY(curl,curl_multi_strerror,
  [
    AC_DEFINE(HAVE_CURL_MULTI_STRERROR,1,[ ])
  ],[],[
    $CURL_LIBS -L$CURL_DIR/$PHP_LIBDIR
  ])

  PHP_NEW_EXTENSION(curl, interface.c multi.c share.c curl_file.c, $ext_shared)
  PHP_SUBST(CURL_SHARED_LIBADD)
fi
