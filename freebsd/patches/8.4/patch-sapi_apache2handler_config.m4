Description: 'make install' installs the module without editing httpd.conf (no apxs -a).
Origin: freebsd-ports lang/php84/files/patch-sapi_apache2handler_config.m4 @ 1a235373d266

--- sapi/apache2handler/config.m4.orig	2026-10-19 14:38:59 UTC
+++ sapi/apache2handler/config.m4
@@ -69,7 +69,7 @@ if test "$PHP_APXS2" != "no"; then
     [AC_MSG_ERROR([Please note that Apache version >= 2.4 is required])])
 
   APXS_LIBEXECDIR='$(INSTALL_ROOT)'$($APXS -q LIBEXECDIR)
-  if test -z $($APXS -q SYSCONFDIR); then
+  if true; then
     INSTALL_IT="\$(mkinstalldirs) '$APXS_LIBEXECDIR' && \
                  $APXS -S LIBEXECDIR='$APXS_LIBEXECDIR' \
                        -i -n php"
