#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""CI 产物自检：确认是 Mach-O arm64/arm64e 动态库（MH_DYLIB）。"""
import struct, sys

FAT_BE = 0xcafebabe
FAT_BE64 = 0xcafebabf
MH64_LE = 0xfeedfacf
CPU = {0x0100000C: 'arm64', 0x0200000C: 'arm64e', 0x01000007: 'x86_64'}
FTYPE = {2: 'MH_EXECUTE', 6: 'MH_DYLIB', 8: 'MH_BUNDLE'}

path = sys.argv[1] if len(sys.argv) > 1 else 'NarutoPlus.dylib'
data = open(path, 'rb').read()
print(f"[*] {path}  {len(data):,} bytes")

ok = True
magic_be = struct.unpack_from('>I', data)[0]
magic_le = struct.unpack_from('<I', data)[0]


def check_slice(off, label):
    global ok
    cputype, cpusub, ftype = struct.unpack_from('<Iii', data, off + 4)[0:3]
    cname = CPU.get(cputype, hex(cputype))
    fname = FTYPE.get(ftype, str(ftype))
    print(f"    [{label}] cputype={cname} subtype=0x{cpusub & 0xffffffff:x} filetype={fname}")
    if cname not in ('arm64', 'arm64e'):
        print("    ❌ 架构不是 arm64/arm64e")
        ok = False
    if ftype != 6:
        print("    ❌ filetype 不是 MH_DYLIB(6)")
        ok = False


if magic_be in (FAT_BE, FAT_BE64):
    n = struct.unpack_from('>I', data, 4)[0]
    print(f"[*] FAT 通用二进制，{n} 个架构")
    for i in range(n):
        off = struct.unpack_from('>I', data, 8 + i * 20 + 8)[0]
        check_slice(off, f"arch{i}")
elif magic_le == MH64_LE:
    print("[*] 单架构 Mach-O 64")
    check_slice(0, 'thin')
else:
    print(f"[!] 未知 magic: 0x{magic_le:08x}")
    ok = False

print("✅ 产物正常：可导入 LiveContainer Tweaks" if ok else "❌ 产物异常")
sys.exit(0 if ok else 1)
