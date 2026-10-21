Description: 'make install' installs the module without editing httpd.conf (no apxs -a).
Origin: freebsd-ports lang/php74/files/patch-sapi_apache2handler_config.m4 @ 036685c034ba

--- sapi/apache2handler/config.m4.orig	2018-08-14 11:39:14 UTC
+++ sapi/apache2handler/config.m4
@@ -65,7 +65,7 @@ if test "$PHP_APXS2" != "no"; then
   fi
 
   APXS_LIBEXECDIR='$(INSTALL_ROOT)'`$APXS -q LIBEXECDIR`
-  if test -z `$APXS -q SYSCONFDIR`; then
+  if true; then
     INSTALL_IT="\$(mkinstalldirs) '$APXS_LIBEXECDIR' && \
                  $APXS -S LIBEXECDIR='$APXS_LIBEXECDIR' \
                        -i -n php7"
