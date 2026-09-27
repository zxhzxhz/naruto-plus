#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""定向探测：只查 Tweaks 与 guest Data，不做全树遍历（零删除）。"""
import asyncio, os, sys, datetime
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.house_arrest import HouseArrestService

LC="com.kdt.livecontainer.8RZ5PBB8K6"; UDID="00008132-000E04E40A45001C"
def log(m): print(m, flush=True)

async def ls(svc, p):
    try:
        r = await svc.listdir(p); return sorted(x for x in r if x not in ('.','..'))
    except Exception as e:
        log(f"   ⚠️ {p}: {e}"); return []

async def info(svc, p):
    try:
        st = await svc.stat(p)
        mt = st.get('st_mtime', 0)
        if isinstance(mt, datetime.datetime): when = mt.strftime('%m-%d %H:%M')
        else: when = datetime.datetime.fromtimestamp(mt/1e9).strftime('%m-%d %H:%M') if mt else '?'
        return f"{st.get('st_size')} B  {when}  {st.get('st_ifmt','')}"
    except Exception as e:
        return f"(stat 失败: {e})"

async def main():
    lk = await create_using_usbmux(serial=UDID)
    async with await HouseArrestService.create(lk, LC) as svc:
        log("### /Documents 顶层")
        for n in await ls(svc, "/Documents"): log(f"   {n}")

        log("\n### /Documents/Tweaks 及其子目录（找 dylib）")
        for sub in await ls(svc, "/Documents/Tweaks"):
            p = f"/Documents/Tweaks/{sub}"
            st = await info(svc, p)
            log(f"   {p}   [{st}]")
            for n in await ls(svc, p):
                if n.endswith(('.dylib','.plist','.json','.txt','.log')):
                    log(f"      └ {n}   [{await info(svc, p+'/'+n)}]")

        log("\n### /Documents/Data/Application（guest 容器）")
        for uuid in await ls(svc, "/Documents/Data/Application"):
            base = f"/Documents/Data/Application/{uuid}"
            doc = base + "/Documents"
            names = await ls(svc, doc)
            mark = ""
            if 'NarutoPlus.json' in names or 'NarutoPlus.log' in names: mark = "  ⭐ 含 NarutoPlus"
            log(f"   {uuid}{mark}")
            if mark:
                for n in names:
                    if 'NarutoPlus' in n or n.endswith(('.plist','.json')) or n.startswith('data'):
                        log(f"      └ {n}   [{await info(svc, doc+'/'+n)}]")
        log("\n### /Documents/Applications（guest 安装的 App 列表）")
        for n in await ls(svc, "/Documents/Applications"): log(f"   {n}")
asyncio.run(main())
