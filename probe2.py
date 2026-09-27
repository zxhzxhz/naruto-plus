import asyncio, datetime
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.house_arrest import HouseArrestService
LC="com.kdt.livecontainer.8RZ5PBB8K6"; UDID="00008132-000E04E40A45001C"
def log(m): print(m, flush=True)
async def ls(svc,p):
    try: return sorted(x for x in await svc.listdir(p) if x not in ('.','..'))
    except Exception: return []
async def info(svc,p):
    try:
        st=await svc.stat(p); mt=st.get('st_mtime',0)
        when = mt.strftime('%m-%d %H:%M') if isinstance(mt,datetime.datetime) else (datetime.datetime.fromtimestamp(mt/1e9).strftime('%m-%d %H:%M') if mt else '?')
        return f"{st.get('st_size')} B  {when}"
    except Exception as e: return f"({e})"
async def main():
    lk=await create_using_usbmux(serial=UDID)
    async with await HouseArrestService.create(lk, LC) as svc:
        # tweak 目录
        log("### tweak 文件")
        for n in await ls(svc, "/Documents/Tweaks/naruto"):
            log(f"   /Documents/Tweaks/naruto/{n}   [{await info(svc, '/Documents/Tweaks/naruto/'+n)}]")
        # guest 容器里含 NarutoPlus 的
        log("\n### guest 容器（Documents 里含 NarutoPlus* 的）")
        for uuid in await ls(svc, "/Documents/Data/Application"):
            doc=f"/Documents/Data/Application/{uuid}/Documents"
            names=await ls(svc, doc)
            hits=[n for n in names if 'NarutoPlus' in n]
            if hits:
                log(f"   ⭐ {uuid}")
                for n in hits:
                    log(f"      └ Documents/{n}   [{await info(svc, doc+'/'+n)}]")
        # 已知的 guest uuid（从日志里读到）
        for uuid in ("FAB6A853-B559-4F81-A872-88978FCB0B54",):
            doc=f"/Documents/Data/Application/{uuid}/Documents"
            names=await ls(svc, doc)
            log(f"\n### 日志中出现的 guest {uuid}: {len(names)} 个条目" + (f"，含 {[n for n in names if 'NarutoPlus' in n]}" if any('NarutoPlus' in n for n in names) else "（无 NarutoPlus）"))
asyncio.run(main())
