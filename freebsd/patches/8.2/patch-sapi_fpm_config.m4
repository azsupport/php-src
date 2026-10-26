Description: Report the listen queue via SO_LISTENQLEN; FreeBSD's struct tcp_info lacks the Linux fields.
Origin: freebsd-ports lang/php82/files/patch-sapi_fpm_config.m4 @ 438e512499a9

--- sapi/fpm/config.m4.orig	2023-03-14 16:11:05 UTC
+++ sapi/fpm/config.m4
@@ -339,7 +339,7 @@ AC_DEFUN([AC_FPM_LQ],
     AC_MSG_RESULT([no])
   ])
 
-  if test "$have_lq" = "tcp_info"; then
+  if test "$have_lq" = "so_listenq"; then
     AC_DEFINE([HAVE_LQ_TCP_INFO], 1, [do we have TCP_INFO?])
   fi
 
