Description: Do not use the Linux aarch64 TLS assembly on FreeBSD (no effect on amd64).
Origin: freebsd-ports lang/php84/files/patch-TSRM_TSRM.c @ fac6f252ac69

--- TSRM/TSRM.c.orig	2024-07-02 13:43:13 UTC
+++ TSRM/TSRM.c
@@ -792,7 +792,7 @@ TSRM_API size_t tsrm_get_ls_cache_tcb_offset(void)
 	asm ("leal _tsrm_ls_cache@ntpoff,%0"
           : "=r" (ret));
 	return ret;
-#elif defined(__aarch64__)
+#elif defined(__aarch64__) && !defined(__FreeBSD__)
 	size_t ret;
 
 # ifdef __APPLE__
