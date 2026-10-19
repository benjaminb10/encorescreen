#!/usr/bin/env python3
# Sets a fixed LC_UUID in every slice of a Mach-O binary. macOS ties the Local Network
# permission to this UUID, which otherwise changes on every build and silently revokes access.
import hashlib, struct, sys

path, seed = sys.argv[1], sys.argv[2]
data = bytearray(open(path, 'rb').read())

def patch(off, arch_tag):
    magic = struct.unpack_from('<I', data, off)[0]
    assert magic == 0xfeedfacf, hex(magic)
    ncmds = struct.unpack_from('<I', data, off + 16)[0]
    p = off + 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', data, p)
        if cmd == 0x1b:  # LC_UUID
            data[p + 8:p + 24] = hashlib.md5(f'{seed}-{arch_tag}'.encode()).digest()
            return
        p += size

if struct.unpack_from('>I', data, 0)[0] == 0xcafebabe:  # universal binary
    n = struct.unpack_from('>I', data, 4)[0]
    for i in range(n):
        cputype, _, offset = struct.unpack_from('>iII', data, 8 + i * 20)
        patch(offset, cputype)
else:
    patch(0, 'single')
open(path, 'wb').write(data)
