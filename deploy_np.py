#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
NarutoPlus 设备部署脚本（pymobiledevice3 / HouseArrest AFC）
- 只做 push/pull，绝不 rm / rename 设备上的文件
- 覆盖前一律先 pull 备份到本地 device_backup/
用法:
    python deploy_np.py recon                # 只读侦察：列目录、定位文件
    python deploy_np.py backup               # 备份 config/log/dylib 到本地
    python deploy_np.py deploy [--config X]  # 上传 dylib + config（先自动备份）
"""
import asyncio
import os
import sys
import datetime
from pathlib import Path

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.house_arrest import HouseArrestService

LC_BUNDLE = os.environ.get("LC_BUNDLE", "com.kdt.livecontainer.8RZ5PBB8K6")
GUEST_BUNDLE = "jp.co.bandainamcoent.BNEI0446"
UDID = os.environ.get("UDID", "00008132-000E04E40A45001C")

HERE = Path(__file__).resolve().parent
BACKUP = HERE / "device_backup"
LOCAL_DYLIB = HERE / "artifact" / "NarutoPlus.dylib"
LOCAL_CFG = HERE / "device_config.json"

# 侦察时要看的目录（相对容器根）
RECON_DIRS = [
    "/",
    "/Documents",
    "/Documents/Tweaks",
]


def log(msg):
    print(msg, flush=True)


async def walk_tree(svc, root, depth, max_depth=3):
    """打印目录树（限深），返回 [(路径, 大小, 是否目录)]"""
    out = []
    try:
        names = await svc.listdir(root)
    except Exception as e:
        log(f"   ⚠️ listdir({root}) 失败: {e}")
        return out
    for n in sorted(names):
        if n in (".", ".."):
            continue
        p = (root.rstrip("/") + "/" + n) if root != "/" else "/" + n
        try:
            st = await svc.stat(p)
            isdir = st.get("st_ifmt") == "S_IFDIR"
            size = st.get("st_size", 0)
        except Exception:
            isdir, size = False, 0
        out.append((p, size, isdir))
        if isdir and len(root.split("/")) < max_depth:
            out += await walk_tree(svc, p, depth + 1, max_depth)
    return out


async def recon():
    lockdown = await create_using_usbmux(serial=UDID)
    log(f"✅ 设备: {lockdown.all_values.get('ProductType')} iOS {lockdown.all_values.get('ProductVersion')}")

    async with await HouseArrestService.create(lockdown, LC_BUNDLE) as svc:
        log(f"✅ HouseArrest(VendContainer) 打开: {LC_BUNDLE}\n")
        entries = await walk_tree(svc, "/", 0, max_depth=int(os.environ.get("DEPTH", "3")))
        log(f"--- 目录条目 {len(entries)} 个 ---")
        for p, size, isdir in entries:
            log(f"{'📁' if isdir else '📄'} {p}" + ("" if isdir else f"   ({size} B)"))

        log("\n--- 关键文件定位 ---")
        hits = [p for p, s, d in entries if not d and ("NarutoPlus" in p or p.endswith(".dylib"))]
        for p in hits:
            st = await svc.stat(p)
            mt = st.get("st_mtime", 0)
            when = datetime.datetime.fromtimestamp(mt / 1e9).strftime("%Y-%m-%d %H:%M:%S") if mt else "?"
            log(f"   {p}  size={st.get('st_size')}  mtime={when}")
        return hits


async def _backup_one(svc, remote, subdir):
    if not await svc.exists(remote):
        log(f"   ⏭ 不存在，跳过: {remote}")
        return None
    data = await svc.get_file_contents(remote)
    dst = BACKUP / subdir / Path(remote).name
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(data)
    log(f"   💾 备份 {remote} → {dst}  ({len(data)} B)")
    return dst


async def backup():
    lockdown = await create_using_usbmux(serial=UDID)
    async with await HouseArrestService.create(lockdown, LC_BUNDLE) as svc:
        entries = await walk_tree(svc, "/", 0, max_depth=int(os.environ.get("DEPTH", "3")))
        files = [p for p, s, d in entries if not d and "NarutoPlus" in p]
        if not files:
            log("⚠️ 没找到任何 NarutoPlus* 文件")
            return
        for p in files:
            sub = "config_log" if p.endswith((".json", ".log")) else "dylib"
            await _backup_one(svc, p, sub)


async def deploy(cfg_local: Path):
    lockdown = await create_using_usbmux(serial=UDID)
    async with await HouseArrestService.create(lockdown, LC_BUNDLE) as svc:
        entries = await walk_tree(svc, "/", 0, max_depth=int(os.environ.get("DEPTH", "4")))
        dylibs = [p for p, s, d in entries if not d and p.endswith("NarutoPlus.dylib")]
        cfgs = [p for p, s, d in entries if not d and p.endswith("NarutoPlus.json")]
        if not dylibs:
            raise SystemExit("❌ 设备上没找到 NarutoPlus.dylib —— 请先在 LiveContainer 里 Import 一次，脚本再覆盖")
        if not cfgs:
            raise SystemExit("❌ 设备上没找到 NarutoPlus.json（先跑一次游戏让它自动生成，或用 --new-config 指定路径）")

        log("--- 先备份原文件 ---")
        for p in dylibs + cfgs:
            sub = "config_log" if p.endswith(".json") else "dylib"
            await _backup_one(svc, p, sub)

        log("\n--- 上传 ---")
        dylib_data = LOCAL_DYLIB.read_bytes()
        for p in dylibs:
            await svc.set_file_contents(p, dylib_data)
            back = await svc.get_file_contents(p)
            ok = len(back) == len(dylib_data)
            log(f"   {'✅' if ok else '❌'} {p}  ← {len(dylib_data)} B (回读 {len(back)} B)")

        cfg_data = cfg_local.read_bytes()
        for p in cfgs:
            await svc.set_file_contents(p, cfg_data)
            back = await svc.get_file_contents(p)
            log(f"   {'✅' if ok else '❌'} {p}  ← {len(cfg_data)} B (回读 {len(back)} B)")
        log("\n完成。若要让新 dylib 生效：LiveContainer 里对该 Tweak 点一次 Sign / 重启游戏。")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "recon"
    if cmd == "recon":
        asyncio.run(recon())
    elif cmd == "backup":
        asyncio.run(backup())
    elif cmd == "deploy":
        cfg = LOCAL_CFG
        if "--config" in sys.argv:
            cfg = Path(sys.argv[sys.argv.index("--config") + 1])
        if not LOCAL_DYLIB.exists():
            raise SystemExit(f"❌ 本地 dylib 不存在: {LOCAL_DYLIB}")
        if not cfg.exists():
            raise SystemExit(f"❌ 本地配置不存在: {cfg}")
        asyncio.run(deploy(cfg))
    else:
        print(__doc__)
