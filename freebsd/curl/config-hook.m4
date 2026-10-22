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
