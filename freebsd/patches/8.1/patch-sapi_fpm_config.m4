Description: Report the listen queue via SO_LISTENQLEN; FreeBSD's struct tcp_info lacks the Linux fields.
Origin: freebsd-ports lang/php81/files/patch-sapi_fpm_config.m4 @ 6002588334a9

--- sapi/fpm/config.m4.orig	2023-03-14 19:50:20 UTC
+++ sapi/fpm/config.m4
@@ -315,7 +315,7 @@ AC_DEFUN([AC_FPM_LQ],
     AC_MSG_RESULT([no])
   ])
 
-  if test "$have_lq" = "tcp_info"; then
+  if test "$have_lq" = "so_listenq"; then
     AC_DEFINE([HAVE_LQ_TCP_INFO], 1, [do we have TCP_INFO?])
   fi
 
