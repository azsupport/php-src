PHP_ARG_WITH([curl],
  [for cURL support],
  [AS_HELP_STRING([--with-curl],
    [Include cURL support (=bundled: ext/curl/libcurl, built into PHP)])])

if test "$PHP_CURL" != "no"; then
  dnl azsupport: --with-curl=bundled builds ext/curl/libcurl (the curl release,
  dnl static and position independent, with the OpenSSL of this PHP build) and
  dnl the libraries it needs (ext/curl/deps: c-ares, nghttp2, brotli, zstd,
  dnl libidn2, libpsl) with ext/curl/build-libcurl.sh and links it into PHP
  dnl instead of a system libcurl: no package needed. Its curl_* symbols are not
  dnl exported (those of its libraries are local in libcurl.a), so a libcurl.so
  dnl that another module loads into the same process stays separate.
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
  PKG_CHECK_MODULES([CURL], [libcurl >= 7.29.0])
  PKG_CHECK_VAR([CURL_FEATURES], [libcurl], [supported_features])

  PHP_EVAL_LIBLINE($CURL_LIBS, CURL_SHARED_LIBADD)
  PHP_EVAL_INCLINE($CURL_CFLAGS)

  AC_MSG_CHECKING([for SSL support in libcurl])
  case "$CURL_FEATURES" in
    *SSL*)
      CURL_SSL=yes
      AC_MSG_RESULT([yes])
      ;;
    *)
      CURL_SSL=no
      AC_MSG_RESULT([no])
      ;;
  esac

  if test "$CURL_SSL" = yes; then
    save_LDFLAGS="$LDFLAGS"
    LDFLAGS="$LDFLAGS $CURL_LIBS"

    AC_MSG_CHECKING([for libcurl linked against old openssl])
    AC_RUN_IFELSE([AC_LANG_SOURCE([[
#include <strings.h>
#include <curl/curl.h>

int main(int argc, char *argv[])
{
  curl_version_info_data *data = curl_version_info(CURLVERSION_NOW);

  if (data && data->ssl_version && *data->ssl_version) {
    const char *ptr = data->ssl_version;

    while(*ptr == ' ') ++ptr;
    if (strncasecmp(ptr, "OpenSSL/1.1", sizeof("OpenSSL/1.1")-1) == 0) {
      /* New OpenSSL version */
      return 3;
    }
    if (strncasecmp(ptr, "OpenSSL", sizeof("OpenSSL")-1) == 0) {
      /* Old OpenSSL version */
      return 0;
    }
    /* Different SSL library */
    return 2;
  }
  /* No SSL support */
  return 1;
}
    ]])],[
      AC_MSG_RESULT([yes])
      AC_DEFINE([HAVE_CURL_OLD_OPENSSL], [1], [Have cURL with old OpenSSL])
      PKG_CHECK_MODULES([OPENSSL], [openssl], [
        PHP_EVAL_LIBLINE($OPENSSL_LIBS, CURL_SHARED_LIBADD)
        PHP_EVAL_INCLINE($OPENSSL_CFLAGS)
        AC_CHECK_HEADERS([openssl/crypto.h])
      ], [])
    ], [
      AC_MSG_RESULT([no])
    ], [
      AC_MSG_RESULT([no])
    ])

    LDFLAGS="$save_LDFLAGS"
  else
    AC_MSG_RESULT([no])
  fi

  PHP_CHECK_LIBRARY(curl,curl_easy_perform,
  [
    AC_DEFINE(HAVE_CURL,1,[ ])
  ],[
    AC_MSG_ERROR(There is something wrong. Please check config.log for more information.)
  ],[
    $CURL_LIBS
  ])

  PHP_NEW_EXTENSION(curl, interface.c multi.c share.c curl_file.c, $ext_shared)
  PHP_INSTALL_HEADERS([ext/curl], [php_curl.h])
  PHP_SUBST(CURL_SHARED_LIBADD)
fi
