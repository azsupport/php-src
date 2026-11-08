#!/usr/bin/env python3
"""elf-export.py - give the global symbols of a relocatable ELF object (64-bit,
little-endian) whose names begin with a prefix the default visibility.

The static libcurl.a of /usr/local/az/static is built with -fvisibility=hidden and
CURL_STATICLIB, so its functions are hidden: PHP links it in and exports none
of them. libcurl.so.4 of the package curl is made of the same objects
(tools/build-deps.sh: ld -r of libcurl.a into one object, then this script on
it for the prefix curl_, then cc -shared with a version script that exports
curl_* only), so that git and the other programs that link libcurl.so.4 find
its API.

Usage: python3 tools/elf-export.py <object.o> <prefix>
Prints the number of symbols changed; exit status 1 when none was found.
"""
import struct
import sys

SHT_SYMTAB = 2
STB_GLOBAL, STB_WEAK = 1, 2
STV_HIDDEN, STV_PROTECTED = 2, 3


def main():
    if len(sys.argv) != 3:
        sys.stderr.write(__doc__.split('\n\n')[-2] + '\n')
        return 2
    path, prefix = sys.argv[1], sys.argv[2].encode()
    with open(path, 'rb') as f:
        data = bytearray(f.read())
    if data[:4] != b'\x7fELF' or data[4] != 2 or data[5] != 1:
        sys.stderr.write('%s: not a 64-bit little-endian ELF file\n' % path)
        return 2
    if struct.unpack_from('<H', data, 0x10)[0] != 1:
        sys.stderr.write('%s: not a relocatable object (ld -r first)\n' % path)
        return 2
    shoff = struct.unpack_from('<Q', data, 0x28)[0]
    shentsize, shnum = struct.unpack_from('<HH', data, 0x3A)
    if shnum == 0:
        shnum = struct.unpack_from('<Q', data, shoff + 0x20)[0]

    def section(i):
        o = shoff + i * shentsize
        name, typ, flags, addr, off, size, link, info, align, entsize = \
            struct.unpack_from('<IIQQQQIIQQ', data, o)
        return typ, off, size, link, entsize

    changed = 0
    for i in range(shnum):
        typ, off, size, link, entsize = section(i)
        if typ != SHT_SYMTAB:
            continue
        _, stroff, strsize, _, _ = section(link)
        for s in range(off, off + size, entsize or 24):
            st_name, st_info, st_other, st_shndx = struct.unpack_from('<IBBH', data, s)
            if st_shndx == 0 or (st_info >> 4) not in (STB_GLOBAL, STB_WEAK):
                continue
            if (st_other & 3) not in (STV_HIDDEN, STV_PROTECTED):
                continue
            n0 = stroff + st_name
            name = bytes(data[n0:data.index(b'\0', n0)])
            if name.startswith(prefix):
                data[s + 5] = st_other & ~3
                changed += 1
    with open(path, 'wb') as f:
        f.write(data)
    print(changed)
    return 0 if changed else 1


if __name__ == '__main__':
    sys.exit(main())
