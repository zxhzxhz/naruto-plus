# NarutoPlus — 火影忍者：究极忍者风暴+ 帧率解锁 / 分辨率 / Direct 直写

> 目标 App：`jp.co.bandainamcoent.BNEI0446`（火影忍者：究极忍者风暴+ · Apple Arcade · ipa.store 版）
> 目标二进制：`narutoNext1` v1.0.1（arm64 thin，NUMM/nucc 引擎 + MoltenVK(Vulkan→Metal)）
> 运行环境：**LiveContainer（ElleKit + TweakLoader）**，也兼容常规越狱注入
> 交付物：`NarutoPlus.dylib`（arm64，GitHub Actions 编译）

---

## 1. 它做了什么

| 需求 | 实现 | 关键位置（RVA，相对 `__TEXT` 基址） |
|---|---|---|
| 破 30fps 上限 → 120fps | ① 代码补丁：VSync 节拍 `16666µs(60Hz)` → `8333µs(120Hz)`<br>② hook 渲染器初始化，把「VSync 分频器」改成 1 | `0x4C678C/0x4C6790/0x4C6794`（节拍立即数）<br>`0x4C3BA0`（`nummRender::Init` 调用点） |
| 渲染分辨率可控 | hook `vkCreateSwapchainKHR` 覆写 `imageExtent`；原生模式时同时改写 `compositeAlpha / imageColorSpace / imageUsage` | `0x5D1504` |
| 从 **Composited** → **Direct** | 渲染分辨率 = 屏幕原生像素 + 图层 `opaque` / `framebufferOnly` + 非 EDR（sRGB）色彩空间 | 同上 + `CAMetalLayer` 属性 hook |
| 可观测 | 日志写 `<guest Documents>/NarutoPlus.log`，含每 N 秒实测 FPS、drawableSize、图层属性、swapchain 原始/覆写参数 | — |

配置热重载：改完 `NarutoPlus.json` 等 ~5 秒自动生效（帧率/节拍类立即生效；**分辨率类建议重启游戏**，或在游戏内切一次画面设置触发 swapchain 重建）。

---

## 2. 逆向结论（这是本补丁的全部依据）

### 2.1 帧率是怎么被锁在 30 的

```
nuccSys::SetFrameRate(uint fps)                        RVA 0x4EA348
    +2451 = fps                                        ← 请求值
    if (fps > 60 || 60 % fps != 0) fps = 60            ← 校验：120 会被吞掉→60
    +2450 = fps                                        ← 生效值（引擎逻辑时间步进用）
    +0x4B8 = 60 / fps                                  ← VSync 分频器 divisor

nummRender::Init(this, w, h, preset, flags, divisor)   实现 RVA 0x4C32BC
    nummRender + 0x9C = divisor                        ← VSync 线程每拍实时读取
    调用点 thunk                                       RVA 0x4C3BA0   ← 本补丁在此改写 divisor

"numm VSyncCallbackThread"（线程体）                    RVA 0x4C6744
    MOV  W24, #0x4119 (16665)  @ +0x48    追赶阈值
    MOV  W25, #0x411A (16666)  @ +0x4C    ★ VSync 周期(µs)，硬编码 60Hz
    MOVN X26, #0x4119 (=-16666) @ +0x50   相位回退
    loop {
        if (++counter >= divisor) 唤醒 FrameStartThread;   // 帧唤醒
        per-vsync 回调();                                   // 每拍都跑
        while (now - base < 16666µs) usleep(剩余/2);        // 节拍
        base += 16666µs;
    }
```

⇒ **实际帧率 = 1e6 ÷ 节拍(µs) ÷ divisor**，默认 `16666µs + divisor 2 = 30fps`。
⇒ 120fps 需要两处同时改：**节拍 8333µs** 且 **divisor = 1**（本补丁两处都做了）。
> 注意：`nuccSys + 0x992/0x993`（生效 fps 字节）**本补丁故意不动** —— 避免改动引擎内部逻辑步进的换算基准。

### 2.2 分辨率怎么来的

```
nuccSys::UpdateRenderExtent(this, presetEntry)          RVA 0x4E9AE0
    +1196/+1198 (u16) = UIScreen.nativeBounds（物理像素，按方向交换）
    +1200 = 画质档位   +1204 = 渲染 flags   +0x4B8 = divisor
        ↓ 作为参数
nummRender::Init(w, h, ...)  →  mm 图形层  →  vkCreateSwapchainKHR(imageExtent)
        ↓ MoltenVK (MVKSwapchain::init @0x65ED70)
CAMetalLayer.setDrawableSize: / setOpaque: / setFramebufferOnly: / setDisplaySyncEnabledMVK:
```

`vkCreateSwapchainKHR` 的字段偏移（已与 MoltenVK 内部读法交叉验证，本补丁就改这几个）：

| 偏移 | 字段 | 本补丁原生模式下的强制值 |
|---|---|---|
| +40 | `imageColorSpace` | `0` = SRGB（避免 EDR/P3 触发合成器色调映射） |
| +44/+48 | `imageExtent.width/height` | 配置的分辨率 |
| +56 | `imageUsage` | `0x10` = COLOR_ATTACHMENT（→ MoltenVK 置 `framebufferOnly = YES`） |
| +84 | `compositeAlpha` | `1` = OPAQUE |
| +88 | `presentMode` | 默认保持引擎值（FIFO）；`noVsync=true` 时改 `0` = IMMEDIATE |

### 2.3 Metal HUD 的 Composited / Direct 是什么

Metal HUD 那行显示的是 **iOS 的呈现路径**：

* **Direct** = drawable 直接扫描输出（direct scanout）；
* **Composited** = 由窗口合成器合成（存在缩放 / 透明 / 被读回 / 色彩空间需转换 / 上方还有别的图层等）。

因此本补丁的做法是：**渲染分辨率做到和屏幕物理像素一致 + 图层不透明 + framebufferOnly + sRGB**。
若日志里 `[SC]` 行显示引擎原本就在请求原生分辨率，那 Composited 的成因通常是 `colorspace`（EDR/P3）
或 `usage`（带 TRANSFER_SRC → framebufferOnly=NO）——本补丁的 `forceDirect` 正好覆盖这两点。

---

## 3. 安装（LiveContainer）

1. 下载本仓库 Actions 产物 `NarutoPlus-dylib`（或本地 `artifact/NarutoPlus.dylib`）。
2. LiveContainer → **Tweaks** → `+` → **New Folder**（例如 `naruto`）→ 进入该文件夹 → `+` → **Import Tweak** → 选 `NarutoPlus.dylib`。
3. App 列表 → 火影忍者 → **App 设置 → Tweak Folder → `naruto`**（shared app 需先 `Convert to Private App`）。
4. 启动游戏，玩到有画面（过 title）后等 10 秒。
5. 取日志：LiveContainer → App 设置 → **Open Data Folder**，`Documents/NarutoPlus.log`；
   首次运行会自动生成 `Documents/NarutoPlus.json`。

> 也可以把 dylib 放到全局 Tweaks 文件夹，但本补丁只对映像名含 `narutoNext1` 的进程生效，放哪都不会误伤宿主 App。

---

## 4. 配置（`Documents/NarutoPlus.json`）

```jsonc
{
  "enabled": true,        // 总开关：false = 完全不介入
  "probe": false,         // true = 只观察打印，不改任何参数（第一次排查建议先 true 跑一次）

  // ★ 开关①：帧率
  "frameRate": 120,       // 0=不改 / 30 / 60 / 120
  "pacerHz": 0,           // VSync 节拍 Hz，0 = 自动（= max(frameRate,60)）
  "logicFps": 0,          // 0 = 与 frameRate 相同；填 30 = 每 4 拍才唤醒一次帧（帧率也随之降到 30）
  "engineFps": 0,         // 直写引擎 fps 字节；0 = 不碰（保持游戏原值 30，最安全）
                          //   ⚠️ 写 >60 会在进 3D 场景时闪退（引擎自带校验 fps>60||60%fps → 60，
                          //      且 60/120=0 会落进 nuccSys+0x4B8）
  "timeBase": 0,          // 直写全引擎时间基 dword_100D59FC8（默认 3000 单位/秒）
                          //   ★ 120fps + 时间流速 1.0× 用 750（60fps 用 1500；0 = 不碰）
  "clockCompensate": true,// 主时钟补偿：把 per-vsync 回调里的 ÷60 补成 ÷(字节×分频器)
                          //   ★ 缺了它会「动画 1× 但主时钟 N×」→ 标题/时序乱跳（已实测）

  // ★ 开关②：分辨率
  "resolution": "native", // "native" | "1.0"/"0.75"/"0.5"(按屏幕像素比例) | "1920x1080"(固定)

  // 进阶
  "forceDirect": true,         // 原生分辨率时强制 compositeAlpha=OPAQUE / 图层 opaque（安全档）
  "directUsage": false,        // 激进档：把 imageUsage 改成「仅 COLOR_ATTACHMENT」
                               //   → MoltenVK 置 framebufferOnly=YES（若引擎会 blit swapchain 图像，
                               //      画面可能变黑，改回 false 立即恢复）
  "forceContentsScale": false, // 实验档：强制 layer.contentsScale = UIScreen.nativeScale
  "allowEngineFpsOver60": false,// 危险档：允许引擎 fps 字节 >60（默认禁止；开启后本补丁会用
                                //   UpdateRenderExtent 守卫把 60/fps=0 立即纠回，但仍可能闪退）
  "noVsync": false,            // true = presentMode 改 IMMEDIATE（更低延迟，可能撕裂）
  "captureStderr": true,       // 把游戏引擎自己的 NSLog/stderr 也写进同一日志
  "statSeconds": 5             // STAT 统计窗口（秒）
}
```

常用组合：

| 目的 | 配置 |
|---|---|
| 120fps + 原生分辨率（期望 Direct） | `frameRate:120, resolution:"native"` |
| 先求稳，只跑到 60 | `frameRate:60, resolution:"native"` |
| 掉帧时降负载 | `frameRate:120, resolution:"0.75"` |
| 强制固定 1080p | `resolution:"1920x1080"` |
| 120fps + 时间流速正确（v1.5 推荐先测这条） | `frameRate:120, engineFps:0, timeBase:750` |
| 120fps 但接受 4× 快进 | `frameRate:120, engineFps:0, timeBase:0` |
| 只跑 60fps（画面与逻辑都 1×） | `frameRate:60, engineFps:0` |
| 逻辑要按原样 30Hz（帧率也会掉到 30） | `frameRate:120, logicFps:30` |

---

## 5. 怎么判断成功（读日志）

日志关键行（出现顺序）：

```
指纹自检: Init=1 Pacer=1 vkCreateSwapchain=1 SetFrameRate=1     ← 全 1 = 二进制匹配
Hook 引擎: MSHookFunction=0x...                                  ← 非 0 = ellekit 正常
✅ hook nummRender::Init 调用点 / ✅ hook vkCreateSwapchainKHR / CAMetalLayer hooks: 5/5
开关①帧率  : frameRate=120
             VSync 节拍 120Hz(8333µs) ÷ 分频器 1 → 目标 120 fps
开关②分辨率: native → 渲染 2732x2048  = 原生像素 → 期望 Metal HUD 显示 Direct
✅ VSync 节拍补丁: 16666µs → 8333µs (120Hz)   [52882338 52882359 9288233a → ...]
环境: iPad Pro / iOS 17.x  面板最大刷新率 120Hz  nativeBounds 2732x2048 px
[INIT] nummRender::Init 引擎入参 w=2732 h=2048 … →  改写 w=2732 h=2048 divisor=1
[SC] #1 vkCreateSwapchainKHR 原始: extent=2732x2048 colorspace=1000104003 usage=0x1 alpha=8 presentMode=2
[SC] #1 覆写后: extent=2732x2048 colorspace=0 usage=0x10 alpha=1 presentMode=2   (直写目标=1 noVsync=0)
[LAYER] setDrawableSize: 2732x2048   (屏幕原生 2732x2048)
[STAT] 实测 118.7 fps (594 帧 / 5.0s) · drawableSize=2732x2048 · layer(opaque=1 fbOnly=1 vsync=1) · 分频器=1 节拍=120Hz · 原生分辨率
```

判定要点：

| 现象 | 含义 |
|---|---|
| `[STAT] 实测 ~120fps` | 帧率解锁成功 |
| `[STAT] 实测 ~30fps` 且 `分频器=1 节拍=120Hz` | 分频器没生效 → 看 `[INIT]` 行是否出现（没出现 = Init hook 未命中） |
| `[STAT] 实测 ~60fps` | 节拍补丁没生效（看 `✅ VSync 节拍补丁` 行），或面板实际跑在 60Hz |
| `指纹自检` 有 0 | 二进制版本不是 1.0.1 → 需要重新定位（把日志发我） |
| `MSHookFunction=0x0` | ellekit 未加载 → 帧率会走轮询降级，分辨率无法生效 |
| Metal HUD 仍显示 Composited | 看 `[SC]` 覆写后的 `colorspace/usage/alpha` 是否已是 `0 / 0x10 / 1`；若已是却仍 Composited，则成因在别处（例如 LiveContainer 宿主窗口层级） |

---

## 6. 已知风险与预期

1. **游戏逻辑速度**：本补丁只动「帧唤醒节拍 + 分频器」，不动引擎的 fps 字节（`+0x992`），
   因此若该引擎的逻辑是「按帧步进」的固定时间步，120fps 下逻辑会**变快**（4×）。
   若实测变快，用 `logicFps: 30`（节拍 120Hz、每 4 拍唤醒一次帧）或 `frameRate: 60` 对照测试。
2. **120fps 只对 ProMotion（120Hz）设备物理可达**；60Hz 机型上设 120 会掉帧（日志会警告）。
3. **代码补丁需要可写代码页**：从 `/log` 里看 `✅ VSync 节拍补丁`，失败会给 `❌ vm_protect` 行。
4. **`noVsync: true`** 会关掉 MoltenVK 的 vsync 等待，可能出现画面撕裂；默认关闭。
5. 分辨率改小 = 由图层放大上屏，属于「Composited」路径（这是分辨率缩放的本质，不是 bug）。
6. 一切改动都在内存中（代码补丁/运行时 hook），**重启游戏即恢复原样**；`enabled:false` 可完全停用。

---

## 7. 文件清单

| 文件 | 用途 |
|---|---|
| `NarutoPlus.m` | 补丁主源码（纯 ObjC/C：代码补丁 + 3 个 C hook + 5 个 ObjC swizzle + 日志/配置/FPS 统计） |
| `Makefile` | Theos 工程（`library.mk`，不链接 CydiaSubstrate / 不用 Logos） |
| `.github/workflows/build.yml` | CI：三层兜底编译（Theos arm64 → arm64+arm64e → apt clang+ld64.lld）+ Mach-O 校验 + artifact |
| `ci_verify.py` | 产物自检（arm64 MH_DYLIB） |
| `config.sample.json` | 配置模板（首次运行会在 Documents 自动生成同名文件） |
| `artifact/NarutoPlus.dylib` | 已下载的构建产物（部署用） |

## 8. 版本历史

| 版本 | 内容 |
|---|---|
| v1.0 | 首版：VSync 节拍补丁 + Init 分频器改写 + swapchain 分辨率/直写属性 hook + 图层统计；配置双开关 + 热重载 |
| **v1.5.1** | 修 v1.5 引入的启动崩溃：`NpConfigLoad()` 里新增的「模型预测」日志块在 `gBase` 尚未赋值时就调用 `NpEngineFpsByte()`，解引用 `0 + 0xFDEC00` 野指针 → 启动即闪退（日志只剩 1 行配置行）。修法：`NpEngineFpsByte()`/新增 `NpTimeBaseLive()` 加 `gBase` 守卫，并把预测日志整块**移到 `NpApplyConfig()`**（映像已就位后执行） |
| **v1.5** | 找到真正的时间基杠杆：步进公式里的 `3000` 不是立即数，而是全局 `dword_100D59FC8`（`ADRL; LDR W8,[X8]; LDRB W9,[nuccSys+0x992]; UDIV`，被 60+ 处代码引用）。新增 `timeBase` 配置直写该全局（`__TEXT,__const` 走 vm_protect），可在 **fps 字节保持游戏原值 30、绝不触发 >60 闪退** 的前提下把步进改成 1/120；`engineFps` 语义改为「0 = 不碰」；日志同时打印两条模型的流速预测（A：引擎另有固定 3000 实时基准 → 改时间基有效；B：全局即单位基准 → 改时间基无效） |
| **v1.4** | 新增 `nuccSys::UpdateRenderExtent` hook（守卫 `60/fps=0` 的落地）+ `allowEngineFpsOver60` 危险档：默认仍钳 60；开启后允许把 fps 字节写成 120（配合 UpdateRenderExtent 守卫做「120fps + 步进 1/120 = 时间流速 1.0×」的验证）。同时给 `NpEnforceEngineState` 加了空状态早退 |
| **v1.3** | **止血 + 模型自证**：1) 设备实测「进 3D 场景闪退」的根因是 fps 字节>60 ⇒ `engineFps` 硬钳到 ≤60（引擎自带校验 `fps>60 \|\| 60%fps → 60`，且 60/fps 会算成 0 落进 `nuccSys+0x4B8`），渲染帧率不受影响，仍是「节拍×分频器」；2) `[STAT]` 新增 `时间流速预测 = 实测fps ÷ 引擎字节`，用于一次性判定步进模型（自然模型预测 2x / 备选模型预测 1x） |
| **v1.2** | **解耦「渲染帧率」与「逻辑步进」**：定位到引擎内部时间基 = 3000 单位/秒，逻辑固定步进 = `3000 / nuccSys[+0x992]`（`sub_1004D4838` / `sub_1004F836C` / `sub_10051F96C` / `sub_1005205C8` 四处实锤）。120fps 下若步进仍为 1/30 会 4× 加速 ⇒ 新增 `engineFps`（默认自动 = frameRate）直写 fps 字节=120 → 步进 25/3000 秒 = 1/120，时间流速回归 1.0×；并把「分频器 + fps 字节」的纠正收敛到 `NpEnforceEngineState()`，在 `SetFrameRate` hook 之后、`Init` 之后、每秒轮询三个时机强制执行（游戏自己调 `SetFrameRate(30)` 会被立刻纠回） |
| **v1.1** | 修 `%s` 传 NSString 导致日志乱码；配置改为非原子写+回读校验、无效配置自动备份 `.bad` 并重写；**分辨率改为以「引擎请求的 extent」为原生基准**（不再依赖 UIScreen，constructor 阶段即可正确决策）；`forceDirect` 判定同样去 UIKit 依赖（修复设备实测 direct 未生效）；新增 `[GEO]` 图层/屏幕几何快照、`directUsage` / `forceContentsScale` 实验开关；STAT 行补充 Init/SetFrameRate 调用计数与 swapchain 原始→覆写尺寸 |
