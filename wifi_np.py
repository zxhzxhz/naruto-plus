#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
NarutoPlus 设备读写（无线 RSD 隧道优先，失败回退 USB HouseArrest）
隧道由 C:\\Users\\zxhzx\\ipad-wifi\\start-wifi-tunnel-ip.cmd 提供，端点从 wifi-tunnel-ip.log 读取。

用法:
    python wifi_np.py ls                 # 列 tweak 目录 + guest Documents
    python wifi_np.py pull [tag]         # 拉 NarutoPlus.log / .crash.log / .state 到 device_backup/<tag>/
    python wifi_np.py push               # 推 artifact/NarutoPlus.dylib + device_config.json
零删除：只做 listdir / get_file_contents / set_file_contents。
"""
import asyncio
import datetime
import hashlib
import os
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TUNNEL_LOG = Path(r"C:\Users\zxhzx\ipad-wifi\wifi-tunnel-ip.log")

LC = "com.kdt.livecontainer.8RZ5PBB8K6"
UDID = "00008132-000E04E40A45001C"
TWEAK_DIR = "/Documents/Tweaks/naruto"
GUEST_DOC = "/Documents/Data/Application/FAB6A853-B559-4F81-A872-88978FCB0B54/Documents"
DYLIB = TWEAK_DIR + "/NarutoPlus.dylib"
CFG = GUEST_DOC + "/NarutoPlus.json"
PULL_FILES = ["NarutoPlus.log", "NarutoPlus.crash.log", "NarutoPlus.state", "NarutoPlus.json", "NarutoShim.log"]


def log(m):
    print(m, flush=True)


def sha(b):
    return hashlib.sha256(b).hexdigest()[:16]


def rsd_endpoint():
    """从隧道日志里取最后一个 RSD <host> <port>"""
    try:
        txt = TUNNEL_LOG.read_text(encoding="utf-8", errors="ignore")
    except Exception:
        return None
    m = re.findall(r"RSD\s+(\S+)\s+(\d+)", txt)
    if not m:
        return None
    host, port = m[-1]
    return host, int(port)


async def make_provider():
    """优先 RSD 隧道；不可用则回退 USB usbmux"""
    ep = rsd_endpoint()
    if ep:
        try:
            from pymobiledevice3.remote.remote_service_discovery import RemoteServiceDiscoveryService
            rsd = RemoteServiceDiscoveryService(ep)
            await rsd.connect()
            log(f"🔗 无线 RSD 隧道: {ep[0]}:{ep[1]}  peer={rsd.peer_info.get('ProductType','?') if rsd.peer_info else '?'}")
            return rsd, "rsd"
        except Exception as e:
            log(f"⚠️ RSD 隧道不可用({type(e).__name__}: {e}) → 回退 USB")
    from pymobiledevice3.lockdown import create_using_usbmux
    lk = await create_using_usbmux(serial=UDID)
    log("🔗 USB usbmux（回退）")
    return lk, "usb"


async def with_afc(fn):
    from pymobiledevice3.services.house_arrest import HouseArrestService
    provider, kind = await make_provider()
    try:
        svc = await HouseArrestService.create(provider, LC)
    except Exception as e:
        log(f"❌ HouseArrest 打开失败: {e}")
        raise
    async with svc:
        return await fn(svc, kind)


async def do_ls(svc, kind):
    for d in (TWEAK_DIR, GUEST_DOC):
        log(f"\n### {d}")
        try:
            for n in sorted(x for x in await svc.listdir(d) if x not in (".", "..")):
                p = f"{d}/{n}"
                try:
                    st = await svc.stat(p)
                    mt = st.get("st_mtime", 0)
                    when = mt.strftime("%m-%d %H:%M:%S") if isinstance(mt, datetime.datetime) else \
                           (datetime.datetime.fromtimestamp(mt / 1e9).strftime("%m-%d %H:%M:%S") if mt else "?")
                    log(f"   {n:28s} {st.get('st_size', 0):>9} B  {when}")
                except Exception as e:
                    log(f"   {n:28s} (stat 失败 {e})")
        except Exception as e:
            log(f"   ⚠️ {e}")


async def do_pull(svc, kind, tag):
    out = HERE / "device_backup" / tag
    out.mkdir(parents=True, exist_ok=True)
    for name in PULL_FILES:
        remote = f"{GUEST_DOC}/{name}"
        try:
            if not await svc.exists(remote):
                log(f"   ⏭ 不存在: {name}")
                continue
            data = await svc.get_file_contents(remote)
            (out / name).write_bytes(data)
            log(f"   💾 {name:26s} {len(data):>8} B  sha {sha(data)}")
        except Exception as e:
            log(f"   ❌ {name}: {type(e).__name__}: {e}")
    log(f"\n→ {out}")


async def do_push(svc, kind):
    dylib = HERE / "artifact" / "NarutoPlus.dylib"
    cfg = HERE / "device_config.json"
    dd = dylib.read_bytes()
    cc = cfg.read_bytes()
    log(f"⬆️ dylib {len(dd)} B sha {sha(dd)}")
    await svc.set_file_contents(DYLIB, dd)
    rb = await svc.get_file_contents(DYLIB)
    log(f"   {'✅' if rb == dd else '❌'} 回读 {DYLIB}")
    log(f"⬆️ config {len(cc)} B")
    await svc.set_file_contents(CFG, cc)
    rb2 = await svc.get_file_contents(CFG)
    log(f"   {'✅' if rb2 == cc else '❌'} 回读 {CFG}")
    log("\n完成（未删除任何设备文件）")


async def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "ls"
    tag = sys.argv[2] if len(sys.argv) > 2 else datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    if cmd == "ls":
        await with_afc(lambda s, k: do_ls(s, k))
    elif cmd == "pull":
        await with_afc(lambda s, k: do_pull(s, k, tag))
    elif cmd == "push":
        await with_afc(lambda s, k: do_push(s, k))
    else:
        print(__doc__)


if __name__ == "__main__":
    asyncio.run(main())
