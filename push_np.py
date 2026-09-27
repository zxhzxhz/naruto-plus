#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""NarutoPlus 设备部署（HouseArrest/AFC）：先备份 → 再上传 → 回读校验。绝不删除设备文件。"""
import asyncio, datetime, hashlib, sys
from pathlib import Path
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.house_arrest import HouseArrestService

LC   = "com.kdt.livecontainer.8RZ5PBB8K6"
UDID = "00008132-000E04E40A45001C"
DYLIB = "/Documents/Tweaks/naruto/NarutoPlus.dylib"
GUEST_DOC = "/Documents/Data/Application/FAB6A853-B559-4F81-A872-88978FCB0B54/Documents"
CFG   = GUEST_DOC + "/NarutoPlus.json"
LOG   = GUEST_DOC + "/NarutoPlus.log"

HERE = Path(__file__).resolve().parent
STAMP = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
BK = HERE / "device_backup" / STAMP
def log(m): print(m, flush=True)
def sha(b): return hashlib.sha256(b).hexdigest()[:16]

async def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "backup"
    lk = await create_using_usbmux(serial=UDID)
    async with await HouseArrestService.create(lk, LC) as svc:
        # ---------- 备份 ----------
        BK.mkdir(parents=True, exist_ok=True)
        for remote, name in ((DYLIB, "NarutoPlus.dylib"), (CFG, "NarutoPlus.json"), (LOG, "NarutoPlus.log")):
            if await svc.exists(remote):
                data = await svc.get_file_contents(remote)
                (BK / name).write_bytes(data)
                log(f"💾 备份 {remote}\n        → device_backup/{STAMP}/{name}  ({len(data)} B, sha {sha(data)})")
            else:
                log(f"⏭  设备上不存在（跳过）: {remote}")
        if mode == "backup":
            log(f"\n备份目录: {BK}")
            return

        # ---------- 上传 ----------
        local_dylib = HERE / "artifact" / "NarutoPlus.dylib"
        local_cfg   = HERE / "device_config.json"
        dd = local_dylib.read_bytes(); cc = local_cfg.read_bytes()
        log(f"\n⬆️ 上传 dylib: {local_dylib.name}  {len(dd)} B  sha {sha(dd)}")
        await svc.set_file_contents(DYLIB, dd)
        rb = await svc.get_file_contents(DYLIB)
        log(f"   {'✅' if rb == dd else '❌'} 回读校验 {DYLIB}: {len(rb)} B  sha {sha(rb)}")
        log(f"⬆️ 上传 config: {len(cc)} B\n{cc.decode('utf-8')}")
        await svc.set_file_contents(CFG, cc)
        rb2 = await svc.get_file_contents(CFG)
        log(f"   {'✅' if rb2 == cc else '❌'} 回读校验 {CFG}: {len(rb2)} B")
        log("\n完成（未删除任何设备文件）。LiveContainer 里对该 tweak 点一次 Sign / 或直接重启游戏即可生效。")

asyncio.run(main())
