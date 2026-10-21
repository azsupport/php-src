Description: Report the listen queue via SO_LISTENQLEN; FreeBSD's struct tcp_info lacks the Linux fields.
Origin: freebsd-ports lang/php83/files/patch-sapi_fpm_config.m4 @ fac6f252ac69

--- sapi/fpm/config.m4.orig	2023-06-06 15:54:29 UTC
+++ sapi/fpm/config.m4
@@ -315,7 +315,7 @@ AC_DEFUN([AC_FPM_LQ],
     AC_MSG_RESULT([no])
   ])
 
-  if test "$have_lq" = "tcp_info"; then
+  if test "$have_lq" = "so_listenq"; then
     AC_DEFINE([HAVE_LQ_TCP_INFO], 1, [do we have TCP_INFO?])
   fi
 
