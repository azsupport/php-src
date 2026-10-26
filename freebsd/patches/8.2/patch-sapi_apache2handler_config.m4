Description: 'make install' installs the module without editing httpd.conf (no apxs -a).
Origin: freebsd-ports lang/php82/files/patch-sapi_apache2handler_config.m4 @ 438e512499a9

--- sapi/apache2handler/config.m4.orig	2023-03-14 16:11:05 UTC
+++ sapi/apache2handler/config.m4
@@ -64,7 +64,7 @@ if test "$PHP_APXS2" != "no"; then
   fi
 
   APXS_LIBEXECDIR='$(INSTALL_ROOT)'`$APXS -q LIBEXECDIR`
-  if test -z `$APXS -q SYSCONFDIR`; then
+  if true; then
     INSTALL_IT="\$(mkinstalldirs) '$APXS_LIBEXECDIR' && \
                  $APXS -S LIBEXECDIR='$APXS_LIBEXECDIR' \
                        -i -n php"
