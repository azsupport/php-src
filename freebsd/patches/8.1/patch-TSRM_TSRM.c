Description: Do not use the Linux aarch64 TLS assembly on FreeBSD (no effect on amd64).
Origin: freebsd-ports lang/php81/files/patch-TSRM_TSRM.c @ 6002588334a9

--- TSRM/TSRM.c.orig	2023-04-12 03:52:48 UTC
+++ TSRM/TSRM.c
@@ -750,7 +750,7 @@ TSRM_API size_t tsrm_get_ls_cache_tcb_offset(void)
 	asm ("leal _tsrm_ls_cache@ntpoff,%0"
           : "=r" (ret));
 	return ret;
-#elif defined(__aarch64__)
+#elif defined(__aarch64__) && !defined(__FreeBSD__)
 	size_t ret;
 
 # ifdef __APPLE__
