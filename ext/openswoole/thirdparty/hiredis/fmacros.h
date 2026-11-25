#ifndef __HIREDIS_FMACRO_H
#define __HIREDIS_FMACRO_H

/* azsupport: not on FreeBSD, where _XOPEN_SOURCE and _POSIX_C_SOURCE hide the BSD
 * types (u_int32_t) that <netinet/ip6.h> needs, which net.c gets through
 * swoole_socket.h; the default environment of FreeBSD has POSIX, XSI and BSD
 * (hiredis before 1.0 left FreeBSD out the same way). */
#ifndef __FreeBSD__
#define _XOPEN_SOURCE 600
#define _POSIX_C_SOURCE 200112L
#endif

#if defined(__APPLE__) && defined(__MACH__)
/* Enable TCP_KEEPALIVE */
#define _DARWIN_C_SOURCE
#endif

#endif
