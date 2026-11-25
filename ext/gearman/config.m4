dnl Gearman PHP Extension
dnl
dnl Copyright (C) 2008 James M. Luedke <contact@jamesluedke.com>,
dnl                    Eric Day <eday@oddments.org>
dnl All rights reserved.
dnl
dnl Use and distribution licensed under the PHP license.  See
dnl the LICENSE file in this directory for full text.

CFLAGS="$CFLAGS -Wall"

PHP_ARG_WITH(gearman, whether to enable gearman support,
[[  --with-gearman[=PATH]   Include gearman support]])

if test "$PHP_GEARMAN" != "no"; then
  HOMEBREW_PREFIX=""
  if command -v brew >/dev/null 2>&1; then
    HOMEBREW_PREFIX=$(brew --prefix gearman 2>/dev/null)
  fi
  for i in $PHP_GEARMAN /usr/local /usr /opt/local $HOMEBREW_PREFIX; do
    if test -r $i/include/libgearman-1.0/gearman.h; then
      GEARMAN_LIB_DIR=$i/$PHP_LIBDIR
      GEARMAN_INC_DIR=$i/include
      AC_MSG_RESULT([found in $i])
      break
    fi
  done

  if test -z "$GEARMAN_LIB_DIR" -o -z "$GEARMAN_INC_DIR"; then
     AC_MSG_RESULT([not found])
     AC_MSG_ERROR([Please install libgearman])
  fi

  PHP_CHECK_LIBRARY(gearman, gearman_client_set_context,
  [
    PHP_ADD_LIBRARY_WITH_PATH(gearman, $GEARMAN_LIB_DIR, GEARMAN_SHARED_LIBADD)
    AC_DEFINE(HAVE_GEARMAN, 1, [Whether you have gearman])
  ],[
    AC_MSG_ERROR([libgearman version 0.10 or later required])
  ],[
    -L$GEARMAN_LIB_DIR -R$GEARMAN_LIB_DIR
  ])

  PHP_CHECK_LIBRARY(gearman, gearman_worker_set_server_option,
  [
    PHP_ADD_LIBRARY_WITH_PATH(gearman, $GEARMAN_LIB_DIR, GEARMAN_SHARED_LIBADD)
    AC_DEFINE(HAVE_GEARMAN, 1, [Whether you have gearman])
  ],[
    AC_MSG_ERROR([libgearman version 0.21 or later required])
  ],[
    -L$GEARMAN_LIB_DIR -R$GEARMAN_LIB_DIR
  ])

  PHP_CHECK_LIBRARY(gearman, gearman_job_error,
  [
    PHP_ADD_LIBRARY_WITH_PATH(gearman, $GEARMAN_LIB_DIR, GEARMAN_SHARED_LIBADD)
    AC_DEFINE(HAVE_GEARMAN, 1, [Whether you have gearman])
  ],[
    AC_MSG_ERROR([libgearman version 1.1.0 or later required])
  ],[
    -L$GEARMAN_LIB_DIR -R$GEARMAN_LIB_DIR
  ])

  PHP_CHECK_LIBRARY(gearman, gearman_client_unique_status,
  [
    PHP_ADD_LIBRARY_WITH_PATH(gearman, $GEARMAN_LIB_DIR, GEARMAN_SHARED_LIBADD)
    AC_DEFINE(HAVE_GEARMAN, 1, [Whether you have gearman])
  ],[
    AC_MSG_ERROR([libgearman version 1.1.0 or later required])
  ],[
    -L$GEARMAN_LIB_DIR -R$GEARMAN_LIB_DIR
  ])

  PHP_CHECK_LIBRARY(gearman, gearman_client_set_ssl,
  [
    AC_DEFINE(HAVE_GEARMAN_CLIENT_SET_SSL, 1, [Whether gearman_client_set_ssl is available])
  ],[],[
    -L$GEARMAN_LIB_DIR -R$GEARMAN_LIB_DIR
  ])

  PHP_CHECK_LIBRARY(gearman, gearman_worker_set_ssl,
  [
    AC_DEFINE(HAVE_GEARMAN_WORKER_SET_SSL, 1, [Whether gearman_worker_set_ssl is available])
  ],[],[
    -L$GEARMAN_LIB_DIR -R$GEARMAN_LIB_DIR
  ])

  AC_MSG_CHECKING([for GEARMAN_WORKER_SSL option])
  old_CPPFLAGS="$CPPFLAGS"
  CPPFLAGS="$CPPFLAGS -I$GEARMAN_INC_DIR"
  AC_COMPILE_IFELSE([AC_LANG_PROGRAM([[#include <libgearman-1.0/gearman.h>]],
    [[int x = GEARMAN_WORKER_SSL;]])],
    [AC_MSG_RESULT([yes])
     AC_DEFINE(HAVE_GEARMAN_WORKER_SSL_OPTION, 1, [Whether GEARMAN_WORKER_SSL option is available])],
    [AC_MSG_RESULT([no])]
  )
  CPPFLAGS="$old_CPPFLAGS"

  PHP_SUBST(GEARMAN_SHARED_LIBADD)

  PHP_ADD_INCLUDE($GEARMAN_INC_DIR)
  PHP_NEW_EXTENSION(gearman, php_gearman.c php_gearman_client.c php_gearman_worker.c php_gearman_job.c php_gearman_task.c, $ext_shared)
fi
