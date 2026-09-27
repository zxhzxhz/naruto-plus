//
//  NarutoPlus.m — 火影忍者：究极忍者风暴+ (iOS/iPadOS)
//                帧率解锁 (30 → 120fps) + 渲染分辨率可控 + Direct 直写图层修正
//  ----------------------------------------------------------------------------
//  目标二进制 : narutoNext1 (v1.0.1, arm64 thin)  NUMM/nucc 引擎 + MoltenVK(Vulkan→Metal)
//  运行环境   : LiveContainer (ellekit / TweakLoader)，也兼容普通越狱注入
//  日志       : <guest Documents>/NarutoPlus.log
//  配置       : <guest Documents>/NarutoPlus.json （首次运行自动生成；解析失败会自动备份重写）
//
//  ============================ 逆向结论（静态定位） ============================
//  RVA = 相对 __TEXT 基址(0x100000000) 的偏移，等价于 Mach-O 文件偏移。
//
//  [1] 帧率链路
//      nuccSys::SetFrameRate(uint fps)                        RVA 0x4EA348
//          +2451 = fps                                        请求值
//          if (fps > 60 || 60 % fps) fps = 60                 校验（120 被吞→60）
//          +2450 = fps                                        生效值（引擎逻辑使用）
//          +0x4B8 = 60 / fps            ← VSync 分频器 divisor
//
//      nummRender::Init(this,w,h,preset,flags,divisor)        实现 RVA 0x4C32BC
//      nummRender::Init 调用点 thunk                           RVA 0x4C3BA0
//          divisor 最终落到 nummRender+0x9C（VSync 线程每拍实时读取）
//
//      "numm VSyncCallbackThread" 线程体                        RVA 0x4C6744
//          MOV W24,#0x4119 (16665)  @ +0x48   追帧阈值
//          MOV W25,#0x411A (16666)  @ +0x4C   VSync 周期(µs) = 60Hz 硬编码
//          MOVN X26,#0x4119 (=-16666) @ +0x50 相位回退
//          循环：++counter >= divisor → 唤醒 FrameStartThread；每拍都跑 per-vsync 回调
//          ⇒ 实际帧率 = 1e6 / 周期 / divisor   （默认 16666µs + divisor 2 = 30fps）
//          ⇒ 120fps 需：周期 8333µs 且 divisor = 1
//
//  [2] 分辨率链路
//      nuccSys::UpdateRenderExtent(this,preset)                RVA 0x4E9AE0
//          +1196/+1198(u16) = UIScreen.nativeBounds（物理像素，按方向交换）
//          → 传给 nummRender::Init(w,h,...) → MoltenVK swapchain extent
//          → CAMetalLayer.setDrawableSize:
//
//  [3] Metal HUD 的 "Composited / Direct"
//      = 窗口合成器合成 vs 直写扫描输出(direct scanout)。
//      控制点 = MoltenVK 的 swapchain 创建入参：
//      vkCreateSwapchainKHR(device, createInfo, alloc, out)    RVA 0x5D1504
//          imageColorSpace @+40   imageExtent @+44/+48   imageUsage @+56
//          compositeAlpha  @+84   presentMode @+88
//      （MoltenVK 内部 MVKSwapchain::init @0x65ED70 把这些字段直接喂给 CAMetalLayer）
//      本补丁在原生分辨率下强制 compositeAlpha=OPAQUE（可选：usage=COLOR_ATTACHMENT
//      → MoltenVK 置 framebufferOnly=YES），并把图层几何/属性全量打进日志供对照。
//
//  ============================ 本补丁做什么 ============================
//      1. 代码补丁：VSync 节拍 16666µs → 1e6/目标Hz（120fps → 8333µs）
//      2. Hook nummRender::Init 调用点：按目标帧率改写 divisor（120fps → 1）
//         （hook 未命中时由 1 秒轮询直接写 nummRender+0x9C 兜底）
//      3. Hook vkCreateSwapchainKHR：分辨率按配置改写；原生分辨率时改直写友好属性
//      4. Hook CAMetalLayer：几何/属性快照、opaque/framebufferOnly/contentsScale 修正、FPS 统计
//      5. 全步骤日志 + 配置热重载
//
//  纯 Objective-C + C 实现：不依赖 Logos / CydiaSubstrate；
//  C 函数 hook 走 ellekit 的 MSHookFunction（缺失时降级为数据轮询，见日志）
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <pthread.h>
#import <math.h>
#import <stdarg.h>
#import <stdio.h>
#import <stdint.h>
#import <stdbool.h>
#import <stdlib.h>
#import <string.h>
#import <fcntl.h>
#import <unistd.h>
#import <dlfcn.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <mach/mach.h>
#import <mach/mach_error.h>
#import <mach-o/dyld.h>
#import <libkern/OSCacheControl.h>

#ifndef PAGE_SIZE
#define PAGE_SIZE 16384u
#endif

#pragma mark - ============================ 常量 ============================

#define NP_VERSION              @"1.6"
#define NP_LOG_FILENAME         @"NarutoPlus.log"
#define NP_CFG_FILENAME         @"NarutoPlus.json"
#define NP_LOG_MAX_BYTES        (12u * 1024u * 1024u)

#define NP_TARGET_IMAGE_NAME    "narutoNext1"

// ---- RVA（narutoNext1 1.0.1） ----
#define RVA_INIT_THUNK          0x4C3BA0u   // nummRender::Init 调用点
#define RVA_PACER_THREAD        0x4C6744u   // numm VSyncCallbackThread 线程体
#define RVA_PACER_MOV_W24       0x4C678Cu   // MOV  W24, #0x4119
#define RVA_PACER_MOV_W25       0x4C6790u   // MOV  W25, #0x411A
#define RVA_PACER_MOVN_X26      0x4C6794u   // MOVN X26, #0x4119 (=-16666)
#define RVA_SET_FRAMERATE       0x4EA348u   // nuccSys::SetFrameRate
#define RVA_UPDATE_RENDER       0x4E9AE0u   // nuccSys::UpdateRenderExtent（写 +0x4B8/+0x1196/1198）
#define RVA_UPDATE_RENDER_EXT   0x4E9AE0u   // nuccSys::UpdateRenderExtent（文档用）
#define RVA_VK_CREATE_SWAPCHAIN 0x5D1504u   // vkCreateSwapchainKHR
#define RVA_MVK_SWAPCHAIN_INIT  0x65ED70u   // MVKSwapchain::init（文档用）
#define RVA_NUCCSYS_INSTANCE    0xFDEC00u   // qword_100FDEC00 = nuccSys 单例指针
#define RVA_NUMMRENDER_INSTANCE 0xF7F328u   // mmSingleton<nummRender,...>::s_Instance
#define RVA_TIME_BASE_GLOBAL    0xD59FC8u   // dword_100D59FC8 = 3000（全引擎时间基，__TEXT,__const）
#define TIME_BASE_DEFAULT       3000u
#define NP_IMAGE_MAX_RVA        0x12B8000u  // narutoNext1 文件大小（用于指针→RVA 映射）

// nuccSys 字段
#define OFF_NUCC_RENDER_W       1196u       // +0x4AC
#define OFF_NUCC_RENDER_H       1198u       // +0x4AE
#define OFF_NUCC_FPS_DIVISOR    1208u       // +0x4B8
#define OFF_NUCC_FPS_EFFECTIVE  2450u       // +0x992 生效 fps（= 固定步进 3000/fps 的来源）
#define OFF_NUCC_FPS_REQUESTED  2451u       // +0x993 请求 fps
#define NUCC_TIME_BASE_PER_SEC  3000u       // 引擎内部时间基：3000 单位 = 1 秒
#define OFF_NUMM_FPS_DIVISOR    0x9Cu       // nummRender+156

// VkSwapchainCreateInfoKHR 字段偏移（与 MoltenVK 内部读法交叉验证过）
#define VKSCI_COLORSPACE        40u
#define VKSCI_EXTENT            44u
#define VKSCI_USAGE             56u
#define VKSCI_COMPOSITE_ALPHA   84u
#define VKSCI_PRESENT_MODE      88u
#define VKSCI_SIZE              104u

#define VK_COMPOSITE_ALPHA_OPAQUE_BIT   1u
#define VK_COLOR_SPACE_SRGB             0u
#define VK_IMAGE_USAGE_COLOR_ATTACHMENT 0x10u
#define VK_IMAGE_USAGE_TRANSFER_MASK    (0x1u | 0x2u)
#define VK_PRESENT_MODE_IMMEDIATE       0u

#pragma mark - ============================ 日志 ============================

static int              gLogFD    = -1;
static BOOL             gLogReady = NO;
static pthread_mutex_t  gLogLock  = PTHREAD_MUTEX_INITIALIZER;
static NSTimeInterval   gStartTs  = 0;

static NSString *NpLogPath(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (dir.length == 0) dir = NSTemporaryDirectory();
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return [dir stringByAppendingPathComponent:NP_LOG_FILENAME];
}

static void NpLogOpen(void)
{
    if (gLogReady) return;
    NSString *path = NpLogPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attr = [fm attributesOfItemAtPath:path error:NULL];
    if (attr && [attr fileSize] > NP_LOG_MAX_BYTES) {
        NSString *old = [path stringByAppendingString:@".old"];
        [fm removeItemAtPath:old error:NULL];
        [fm moveItemAtPath:path toPath:old error:NULL];
    }
    int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    gLogFD = fd;
    gLogReady = YES;
}

// 把引擎自身 stderr(NSLog/printf) 也引到同一文件（配置项 captureStderr）
static void NpRedirectStderr(void)
{
    if (!gLogReady) return;
    int fd2 = open(NpLogPath().fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd2 < 0) return;
    fflush(stderr);
    dup2(fd2, STDERR_FILENO);
    close(fd2);
    setvbuf(stderr, NULL, _IONBF, 0);
}

static void NpLog(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (gStartTs == 0) gStartTs = now;
    NSString *line = [NSString stringWithFormat:@"[%8.3fs] %@\n", now - gStartTs, msg];

    pthread_mutex_lock(&gLogLock);
    if (gLogFD >= 0) {
        const char *c = line.UTF8String;
        ssize_t ignored = write(gLogFD, c, strlen(c));
        (void)ignored;
    }
    pthread_mutex_unlock(&gLogLock);
    NSLog(@"[NarutoPlus] %@", msg);
}

#define NPLOG(...) NpLog(__VA_ARGS__)

#pragma mark - ============================ 基础工具 ============================

static uintptr_t gBase = 0;
static void *np_at(uint32_t rva) { return (void *)(gBase + (uintptr_t)rva); }

static uint32_t np_rd32(uintptr_t a) { return *(volatile uint32_t *)a; }
static uint16_t np_rd16(uintptr_t a) { return *(volatile uint16_t *)a; }
static void     np_wr32(uintptr_t a, uint32_t v) { *(volatile uint32_t *)a = v; }
static void     np_wr16(uintptr_t a, uint16_t v) { *(volatile uint16_t *)a = v; }
static void     np_wr8 (uintptr_t a, uint8_t  v) { *(volatile uint8_t  *)a = v; }

static NSString *np_hexdump(const void *p, size_t n)
{
    const uint8_t *b = (const uint8_t *)p;
    NSMutableString *s = [NSMutableString string];
    for (size_t i = 0; i < n; i++) [s appendFormat:@"%02x ", b[i]];
    return s;
}

static BOOL np_mem_eq(const void *p, const void *ref, size_t n)
{
    return p && memcmp(p, ref, n) == 0;
}

// 前向声明（定义在下方；配置/日志代码会先用到）
static void     NpEnforceEngineState(const char *why);
static uint8_t  NpEngineFpsByte(void);
static uint32_t NpTimeBaseLive(void);

#pragma mark - ============================ 配置 ============================

typedef enum { NpResModeNative = 0, NpResModeScale = 1, NpResModeFixed = 2 } NpResMode;

typedef struct {
    BOOL        enabled;
    BOOL        probe;              // 只观察不改
    int         frameRate;          // 0 = 不改；30 / 60 / 120
    int         pacerHz;            // 0 = 自动（= max(frameRate,60)，上限 120）
    int         logicFps;           // 0 = 与 frameRate 相同（分频器按它算）
    int         engineFps;          // 直写引擎 fps 字节；0 = 不碰（保持游戏原值，推荐）
    int         timeBase;           // 直写全引擎时间基 dword_100D59FC8；0 = 不碰（保持 3000）
    NpResMode   resMode;
    double      resScale;
    int         resW, resH;
    BOOL        forceDirect;        // 原生分辨率时把 swapchain/图层改成直写友好
    BOOL        directUsage;        // 激进档：去掉 TRANSFER_SRC/DST → framebufferOnly=YES
    BOOL        forceContentsScale; // 实验档：强制 layer.contentsScale = UIScreen.nativeScale
    BOOL        allowOver60;        // 危险档：允许把引擎 fps 字节写到 >60（默认禁止，进 3D 场景会闪退）
    BOOL        dumpPointers;       // 诊断：把引擎关键函数指针映射成 RVA 打进日志（默认开，只读）
    BOOL        noVsync;            // presentMode → IMMEDIATE
    BOOL        captureStderr;
    int         statSeconds;
    // 派生（仅用配置算术，不需要 UIKit）
    int         effFps;
    int         effPacerHz;
    int         effDivisor;
    int         effEngineFps;       // 最终写入 nuccSys+0x992 的值
} NpConfig;

static NpConfig  gCfg;
static NSString *gCfgPath = nil;
static time_t    gCfgMTime = 0;

static NSString *NpCfgPath(void)
{
    if (gCfgPath) return gCfgPath;
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (dir.length == 0) dir = NSTemporaryDirectory();
    gCfgPath = [dir stringByAppendingPathComponent:NP_CFG_FILENAME];
    return gCfgPath;
}

static id NpCfgDefaultJSON(void)
{
    return @{
        @"enabled"           : @YES,
        @"probe"             : @NO,
        @"frameRate"         : @120,          // 开关①：0=不改 / 30 / 60 / 120
        @"resolution"        : @"native",     // 开关②："native" | "1.0"/"0.75"(比例) | "1920x1080"
        @"pacerHz"           : @0,
        @"logicFps"          : @0,
        @"engineFps"         : @0,            // 0 = 不碰引擎 fps 字节（保持游戏原值 30，最安全）
        @"timeBase"          : @0,            // 直写时间基 dword_100D59FC8；120fps 想回 1.0× 试 750
        @"forceDirect"       : @YES,
        @"directUsage"       : @NO,
        @"forceContentsScale": @NO,
        @"allowEngineFpsOver60": @NO,         // true = 允许 engineFps>60（引擎未支持，风险自负）
        @"dumpPointers": @YES,                // 诊断：打印引擎函数指针 RVA（只读，用于定位帧管线）
        @"noVsync"           : @NO,
        @"captureStderr"     : @YES,
        @"statSeconds"       : @5
    };
}

static double NpParseResolution(id v, NpResMode *mode, int *w, int *h)
{
    *mode = NpResModeNative; *w = 0; *h = 0;
    if ([v isKindOfClass:[NSNumber class]]) {
        double d = [v doubleValue];
        if (d > 0) { *mode = NpResModeScale; return d; }
        return 0;
    }
    if (![v isKindOfClass:[NSString class]]) return 0;
    NSString *s = [(NSString *)v stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (s.length == 0) return 0;
    if ([s.lowercaseString isEqualToString:@"native"] || [s isEqualToString:@"0"]) return 0;

    NSRange xr = [s rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"x*X×"]];
    if (xr.location != NSNotFound) {
        int a = [[s substringToIndex:xr.location] intValue];
        int b = [[s substringFromIndex:xr.location + 1] intValue];
        if (a > 0 && b > 0) { *mode = NpResModeFixed; *w = a; *h = b; }
        return 0;
    }
    double d = s.doubleValue;
    if (d > 0) { *mode = NpResModeScale; return d; }
    return 0;
}

static void NpConfigDefaults(void)
{
    memset(&gCfg, 0, sizeof(gCfg));
    gCfg.enabled        = YES;
    gCfg.frameRate      = 120;
    gCfg.resMode        = NpResModeNative;
    gCfg.resScale       = 1.0;
    gCfg.forceDirect    = YES;
    gCfg.captureStderr  = YES;
    gCfg.statSeconds    = 5;
}

// 帧率规划：只用配置算术，不需要 UIKit ⇒ constructor 里立即生效
static void NpComputePlan(void)
{
    if (gCfg.frameRate <= 0) {
        gCfg.effFps = 0; gCfg.effPacerHz = 0; gCfg.effDivisor = 0; gCfg.effEngineFps = 0;
        return;
    }
    int pacer = (gCfg.pacerHz > 0) ? gCfg.pacerHz : MAX(gCfg.frameRate, 60);
    if (pacer > 120) pacer = 120;
    if (pacer < gCfg.frameRate) pacer = gCfg.frameRate;
    int logic = (gCfg.logicFps > 0) ? gCfg.logicFps : gCfg.frameRate;
    if (logic > pacer) logic = pacer;
    int div = pacer / logic;
    if (div < 1) div = 1;
    gCfg.effFps = gCfg.frameRate;
    gCfg.effPacerHz = pacer;
    gCfg.effDivisor = div;

    // 引擎 fps 字节：0 = 不碰（保持游戏自己调的值，通常是 30）。
    // ⚠️ 永不写 >60：引擎自带校验 `fps>60 || 60%fps → 60`，实测写 120 会在进 3D 场景时闪退
    //    （60/120=0 落到 nuccSys+0x4B8，且引擎内部有以 60 为前提的表/索引）。
    int ef = gCfg.engineFps;
    if (ef < 0) ef = 0;
    if (ef > 60) {
        if (!gCfg.allowOver60) {
            NPLOG(@"⚠️ engineFps(%d) > 引擎上限 60 → 钳到 60（写 >60 会进 3D 场景闪退）", ef);
            ef = 60;
        } else {
            NPLOG(@"⚠️⚠️ allowEngineFpsOver60=true：将写 %d（实测仍会闪退，仅在加装 UpdateRenderExtent 守卫时做验证）", ef);
        }
    }
    gCfg.effEngineFps = ef;              // 0 = 不写
}

// 非原子写 + 回读校验（LiveContainer 的路径映射下原子写(rename)可能不可靠）
static BOOL NpWriteDefaultConfig(NSString *path)
{
    NSData *d = [NSJSONSerialization dataWithJSONObject:NpCfgDefaultJSON()
                                                options:NSJSONWritingPrettyPrinted error:NULL];
    if (!d) { NPLOG(@"❌ 默认配置序列化失败"); return NO; }
    BOOL ok = [d writeToFile:path atomically:NO];
    NSData *back = [NSData dataWithContentsOfFile:path];
    NPLOG(@"%@ 写入默认配置 %@  (%lu 字节，回读 %lu 字节)",
          (ok && back.length == d.length) ? @"✅" : @"⚠️", path,
          (unsigned long)d.length, (unsigned long)back.length);
    return ok;
}

static void NpConfigLoad(void)
{
    NSString *path = NpCfgPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) == 0) gCfgMTime = st.st_mtime;

    if (![fm fileExistsAtPath:path]) {
        NpConfigDefaults();
        NPLOG(@"未找到配置文件 → 生成默认配置");
        NpWriteDefaultConfig(path);
        NpComputePlan();
        return;
    }

    NSData *d = [NSData dataWithContentsOfFile:path];
    id obj = (d.length > 0) ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
    if (![obj isKindOfClass:[NSDictionary class]]) {
        NSString *head = (d.length > 0) ? np_hexdump(d.bytes, MIN((NSUInteger)24, d.length)) : @"(空文件)";
        NPLOG(@"⚠️ 配置无效（%lu 字节，首字节 %@）→ 备份为 .bad 并重写默认配置",
              (unsigned long)d.length, head);
        if (d.length > 0) {
            NSString *bad = [path stringByAppendingString:@".bad"];
            [fm removeItemAtPath:bad error:NULL];
            [fm moveItemAtPath:path toPath:bad error:NULL];
        } else {
            [fm removeItemAtPath:path error:NULL];
        }
        NpConfigDefaults();
        NpWriteDefaultConfig(path);
        NpComputePlan();
        return;
    }

    NSDictionary *j = (NSDictionary *)obj;
    NpConfigDefaults();

    if (j[@"enabled"])            gCfg.enabled            = [j[@"enabled"] boolValue];
    if (j[@"probe"])              gCfg.probe              = [j[@"probe"] boolValue];
    if (j[@"frameRate"])          gCfg.frameRate          = [j[@"frameRate"] intValue];
    if (j[@"pacerHz"])            gCfg.pacerHz            = [j[@"pacerHz"] intValue];
    if (j[@"logicFps"])           gCfg.logicFps           = [j[@"logicFps"] intValue];
    if (j[@"engineFps"])          gCfg.engineFps          = [j[@"engineFps"] intValue];
    if (j[@"timeBase"])           gCfg.timeBase           = [j[@"timeBase"] intValue];
    if (j[@"forceDirect"])        gCfg.forceDirect        = [j[@"forceDirect"] boolValue];
    if (j[@"directUsage"])        gCfg.directUsage        = [j[@"directUsage"] boolValue];
    if (j[@"forceContentsScale"]) gCfg.forceContentsScale = [j[@"forceContentsScale"] boolValue];
    if (j[@"allowEngineFpsOver60"]) gCfg.allowOver60      = [j[@"allowEngineFpsOver60"] boolValue];
    if (j[@"dumpPointers"])       gCfg.dumpPointers       = [j[@"dumpPointers"] boolValue];
    if (j[@"noVsync"])            gCfg.noVsync            = [j[@"noVsync"] boolValue];
    if (j[@"captureStderr"])      gCfg.captureStderr      = [j[@"captureStderr"] boolValue];
    if (j[@"statSeconds"])        gCfg.statSeconds        = [j[@"statSeconds"] intValue];
    if (j[@"resolution"])         gCfg.resScale           = NpParseResolution(j[@"resolution"], &gCfg.resMode,
                                                                              &gCfg.resW, &gCfg.resH);

    if (gCfg.statSeconds < 1)  gCfg.statSeconds = 1;
    if (gCfg.statSeconds > 60) gCfg.statSeconds = 60;

    NpComputePlan();

    NPLOG(@"配置: enabled=%d probe=%d frameRate=%d resolution=%@ forceDirect=%d directUsage=%d forceContentsScale=%d noVsync=%d pacerHz=%d logicFps=%d",
          gCfg.enabled, gCfg.probe, gCfg.frameRate,
          (gCfg.resMode == NpResModeNative ? @"native"
             : (gCfg.resMode == NpResModeScale ? [NSString stringWithFormat:@"scale %.3f", gCfg.resScale]
                                               : [NSString stringWithFormat:@"%dx%d", gCfg.resW, gCfg.resH])),
          gCfg.forceDirect, gCfg.directUsage, gCfg.forceContentsScale, gCfg.noVsync, gCfg.pacerHz, gCfg.logicFps);
}

#pragma mark - ============================ 目标分辨率推导 ============================

// 关键设计：以「引擎自己请求的 extent」为原生基准，不依赖 UIScreen 查询，
// 这样在 constructor 阶段（UIKit 还没就绪）也能做出正确决策。
static void NpDeriveExtent(int origW, int origH, int *outW, int *outH, BOOL *outIsNative)
{
    int w = origW, h = origH;
    BOOL isNative = YES;

    if (gCfg.resMode == NpResModeScale && gCfg.resScale > 0 && origW > 0 && origH > 0) {
        w = (int)llround((double)origW * gCfg.resScale);
        h = (int)llround((double)origH * gCfg.resScale);
        isNative = NO;
    } else if (gCfg.resMode == NpResModeFixed && gCfg.resW > 0 && gCfg.resH > 0) {
        w = gCfg.resW; h = gCfg.resH;
        if ((origH > origW) != (h > w)) { int t = w; w = h; h = t; }   // 取向对齐引擎
        isNative = (w == origW && h == origH);
    }

    if (w < 320)    w = 320;
    if (h < 240)    h = 240;
    if (w > 16384)  w = 16384;
    if (h > 16384)  h = 16384;

    *outW = w & ~1;
    *outH = h & ~1;
    if (outIsNative) *outIsNative = isNative;
}

// 直写友好模式是否启用（只要是 native 分辨率就有意义，无需查屏幕）
static BOOL NpDirectActive(void)
{
    return (gCfg.enabled && !gCfg.probe && gCfg.forceDirect && gCfg.resMode == NpResModeNative);
}

#pragma mark - ============================ 代码补丁 ============================

static BOOL NpPatchCode(void *addr, const void *bytes, size_t len)
{
    uintptr_t page = (uintptr_t)addr & ~(uintptr_t)(PAGE_SIZE - 1);
    uintptr_t last = ((uintptr_t)addr + len) & ~(uintptr_t)(PAGE_SIZE - 1);
    size_t    span = (size_t)(last - page) + PAGE_SIZE;
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page, (vm_size_t)span,
                                  FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        NPLOG(@"❌ vm_protect(RW) 失败 @%p: %s (%d)", addr, mach_error_string(kr), kr);
        return NO;
    }
    memcpy(addr, bytes, len);
    sys_icache_invalidate(addr, len);
    kr = vm_protect(mach_task_self(), (vm_address_t)page, (vm_size_t)span,
                    FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS)
        NPLOG(@"⚠️ vm_protect(RX) 恢复失败 @%p: %s", addr, mach_error_string(kr));
    return YES;
}

static uint32_t np_movz_w(int rd, uint16_t imm) { return 0x52800000u | ((uint32_t)imm << 5) | (uint32_t)rd; }
static uint32_t np_movn_x(int rd, uint16_t imm) { return 0x92800000u | ((uint32_t)imm << 5) | (uint32_t)rd; }

#pragma mark - ============================ Hook 基建 ============================

typedef void (*MSHookFunction_t)(void *symbol, void *replace, void **result);
static MSHookFunction_t pMSHookFunction = NULL;

static BOOL NpResolveHookEngine(void)
{
    pMSHookFunction = (MSHookFunction_t)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (!pMSHookFunction) pMSHookFunction = (MSHookFunction_t)dlsym(RTLD_DEFAULT, "A3HookFunction");
    NPLOG(@"Hook 引擎: MSHookFunction=%p", (void *)pMSHookFunction);
    return pMSHookFunction != NULL;
}

#pragma mark - ============================ 引擎指针 → RVA 映射（帧管线定位工装） ============================

static uint32_t NpRVAByPtr(uintptr_t p)
{
    if (!gBase || p < gBase) return 0;
    uint64_t off = (uint64_t)(p - gBase);
    if (off == 0 || off >= NP_IMAGE_MAX_RVA) return 0;
    return (uint32_t)off;
}

static void NpDumpPointers(const char *tag)
{
    if (!gBase || !gCfg.dumpPointers) return;
    uintptr_t rend = *(volatile uintptr_t *)(gBase + RVA_NUMMRENDER_INSTANCE);
    if (rend < 0x100000000ULL) return;                 // 引擎尚未初始化

    static const char *names[] = {"vtable", "vsync回调fn", "vsync回调ctx", "分频器",
                                  "FrameStart线程对象", "WaitPrevDraw线程对象", "绘制命令管理器"};
    static const uint32_t offs[] = {0x00, 0x38, 0x40, 0x9C, 0x108, 0x168, 0x1C8};

    NPLOG(@"[DUMP/%@] nummRender @0x%lx  (RVA 0x%x)", [NSString stringWithUTF8String:tag],
          (unsigned long)rend, NpRVAByPtr(rend));
    for (int i = 0; i < 7; i++) {
        uintptr_t v = *(volatile uintptr_t *)(rend + offs[i]);
        NPLOG(@"[DUMP/%@]   +0x%03X %@ = 0x%lx%s", [NSString stringWithUTF8String:tag], offs[i],
              [NSString stringWithUTF8String:names[i]], (unsigned long)v,
              (NpRVAByPtr(v) ? [[NSString stringWithFormat:@"  → RVA 0x%x", NpRVAByPtr(v)] UTF8String] : ""));
    }
    for (int k = 4; k <= 6; k++) {
        uintptr_t o = *(volatile uintptr_t *)(rend + offs[k]);
        if (!NpRVAByPtr(o)) continue;
        for (int j = 0; j < 0x50; j += 8) {
            uintptr_t v = *(volatile uintptr_t *)(o + j);
            uint32_t r = NpRVAByPtr(v);
            if (r) NPLOG(@"[DUMP/%@]   obj(0x%03X)+0x%02X = 0x%lx → RVA 0x%x",
                         [NSString stringWithUTF8String:tag], offs[k], j, (unsigned long)v, r);
        }
    }
}

#pragma mark - ============================ 帧率 ============================

// 前向声明（定义在下方，供前面的配置/日志代码使用）
static void NpEnforceEngineState(const char *why);
static uint8_t NpEngineFpsByte(void);

typedef int64_t (*InitThunkFn)(int16_t w, int16_t h, uint32_t preset, uint32_t flags, uint32_t divisor);
static InitThunkFn gOrigInitThunk = NULL;
static BOOL        gInitThunkHooked = NO;
static volatile int gInitThunkCalls = 0;

typedef int64_t (*SetFrameRateFn)(uintptr_t self, uint32_t fps);
static SetFrameRateFn gOrigSetFrameRate = NULL;
static volatile int   gSetFrameRateCalls = 0;

static int64_t NpHook_InitThunk(int16_t w, int16_t h, uint32_t preset, uint32_t flags, uint32_t divisor)
{
    gInitThunkCalls++;

    if (!gCfg.enabled || gCfg.probe)
        return gOrigInitThunk(w, h, preset, flags, divisor);

    int tw = w, th = h;
    BOOL isNative = YES;
    NpDeriveExtent(w, h, &tw, &th, &isNative);

    uint32_t nd = (gCfg.effDivisor > 0) ? (uint32_t)gCfg.effDivisor : divisor;

    uint8_t engFps = 0;
    uintptr_t inst = *(volatile uintptr_t *)(gBase + RVA_NUCCSYS_INSTANCE);
    if (inst > 0x100000000ULL) engFps = *(volatile uint8_t *)(inst + OFF_NUCC_FPS_EFFECTIVE);
    NPLOG(@"[INIT] #%d nummRender::Init 引擎入参 w=%d h=%d preset=%u flags=0x%x divisor=%u (引擎fps字节=%u)  →  改写 w=%d h=%d divisor=%u  (原生=%d 目标 %dfps / 节拍 %dHz)",
          gInitThunkCalls, w, h, preset, flags, divisor, engFps, tw, th, nd, isNative, gCfg.effFps, gCfg.effPacerHz);
    NpEnforceEngineState("Init后");

    return gOrigInitThunk((int16_t)tw, (int16_t)th, preset, flags, nd);
}

static int64_t NpHook_SetFrameRate(uintptr_t self, uint32_t fps)
{
    gSetFrameRateCalls++;
    int64_t r = gOrigSetFrameRate(self, fps);

    // 游戏会用它重置「分频器 + fps 字节」（+0x992/+0x4B8），必须在返回后立刻纠回，
    // 否则 120fps 会掉回 (60/2)=30fps、或步进回到 1/30 造成 4× 加速。
    uint8_t eff = (self > 0x100000000ULL) ? *(volatile uint8_t *)(self + OFF_NUCC_FPS_EFFECTIVE) : 0;
    uint32_t div = (self > 0x100000000ULL) ? *(volatile uint32_t *)(self + OFF_NUCC_FPS_DIVISOR) : 0;
    NPLOG(@"[FPS] 游戏调用 nuccSys::SetFrameRate(%u) → 引擎内部: fps字节=%u 分频器=%u  (本补丁随后纠正)", fps, eff, div);

    NpEnforceEngineState("SetFrameRate后");
    return r;
}

// hook 不可用 / Init 未命中时的兜底：直接写单例字段（VSync 线程每拍实时读 nummRender+0x9C）
// ── 引擎侧状态强制（唯一收敛点）──
//   nuccSys+0x992 : 生效 fps 字节 → 逻辑固定步进 = 3000/fps 单位（1 单位 = 1/3000 秒）
//   nuccSys+0x4B8 : 60/fps 分频器（引擎自己的记账）
//   nummRender+0x9C : VSync 线程每拍实时读取的分频器 ← 真正决定帧唤醒频率
static void NpEnforceEngineState(const char *why)
{
    if (!gBase || !gCfg.enabled || gCfg.probe) return;

    // 时间基（全局，__TEXT,__const → 需要 vm_protect 写）
    if (gCfg.timeBase > 0) {
        uintptr_t tb = gBase + RVA_TIME_BASE_GLOBAL;
        uint32_t cur = np_rd32(tb);
        if (cur != (uint32_t)gCfg.timeBase) {
            uint32_t v = (uint32_t)gCfg.timeBase;
            if (NpPatchCode((void *)tb, &v, 4))
                NPLOG(@"[FLOW] (%@) 时间基 dword_100D59FC8: %u → %u", [NSString stringWithUTF8String:why], cur, v);
        }
    }

    uintptr_t inst = *(volatile uintptr_t *)(gBase + RVA_NUCCSYS_INSTANCE);
    if (inst > 0x100000000ULL) {
        uint8_t eff = *(volatile uint8_t *)(inst + OFF_NUCC_FPS_EFFECTIVE);
        if (eff != 0 && gCfg.effEngineFps > 0 && eff != (uint8_t)gCfg.effEngineFps) {
            np_wr8(inst + OFF_NUCC_FPS_EFFECTIVE, (uint8_t)gCfg.effEngineFps);
            np_wr8(inst + OFF_NUCC_FPS_REQUESTED, (uint8_t)gCfg.effEngineFps);
            uint32_t tbNow = np_rd32(gBase + RVA_TIME_BASE_GLOBAL);
            NPLOG(@"[STEP] (%@) 引擎 fps 字节 %u → %d  ⇒ 单帧逻辑步进 = 时间基/fps = %u/%u 单位 (旧 %.2f ms/帧)",
                  [NSString stringWithUTF8String:why], eff, gCfg.effEngineFps,
                  tbNow / (uint32_t)gCfg.effEngineFps, tbNow, 1000.0 / (double)eff);
        }
        if (gCfg.effDivisor > 0) {
            uint32_t div = *(volatile uint32_t *)(inst + OFF_NUCC_FPS_DIVISOR);
            if (div != (uint32_t)gCfg.effDivisor) {
                np_wr32(inst + OFF_NUCC_FPS_DIVISOR, (uint32_t)gCfg.effDivisor);
                NPLOG(@"[FPS] (%@) nuccSys+0x4B8 分频器 %u → %d", [NSString stringWithUTF8String:why], div, gCfg.effDivisor);
            }
        }
    }

    uintptr_t rend = *(volatile uintptr_t *)(gBase + RVA_NUMMRENDER_INSTANCE);
    if (rend > 0x100000000ULL && gCfg.effDivisor > 0) {
        uint32_t d2 = *(volatile uint32_t *)(rend + OFF_NUMM_FPS_DIVISOR);
        if (d2 != (uint32_t)gCfg.effDivisor) {
            np_wr32(rend + OFF_NUMM_FPS_DIVISOR, (uint32_t)gCfg.effDivisor);
            NPLOG(@"[FPS] (%@) nummRender+0x9C 分频器 %u → %d", [NSString stringWithUTF8String:why], d2, gCfg.effDivisor);
        }
    }
}

// 兼容旧调用点
static void NpPollNuCCSys(void) { NpEnforceEngineState("轮询"); }

// ── nuccSys::UpdateRenderExtent 守卫 ──
// 该函数会重算 +0x4B8 = 60/fps。fps 字节 >60 时这里算出 0，引擎在 3D 场景初始化路径上
// 读到 0 会直接崩（设备实测：写 120 → 进 3D 场景闪退）。因此每次它跑完立刻纠回。
typedef int64_t (*UpdateRenderExtentFn)(uintptr_t self, void *presetEntry);
static UpdateRenderExtentFn gOrigUpdateRenderExtent = NULL;

static int64_t NpHook_UpdateRenderExtent(uintptr_t self, void *presetEntry)
{
    int64_t r = gOrigUpdateRenderExtent(self, presetEntry);
    NpEnforceEngineState("UpdateRenderExtent后");
    return r;
}

// 读实时时间基（未拿到映像时返回默认值）
static uint32_t NpTimeBaseLive(void)
{
    if (!gBase) return TIME_BASE_DEFAULT;
    return np_rd32(gBase + RVA_TIME_BASE_GLOBAL);
}

// 读当前引擎 fps 字节（仅用于日志）
static uint8_t NpEngineFpsByte(void)
{
    if (!gBase) return 0;                       // 配置加载阶段 gBase 仍为 0，绝不能在此解引用
    uintptr_t inst = *(volatile uintptr_t *)(gBase + RVA_NUCCSYS_INSTANCE);
    if (inst > 0x100000000ULL) return *(volatile uint8_t *)(inst + OFF_NUCC_FPS_EFFECTIVE);
    return 0;
}

static BOOL NpApplyPacerPeriod(int pacerHz)
{
    static const uint8_t fp[16] = {0xfc,0x6f,0xba,0xa9,0xfa,0x67,0x01,0xa9,
                                   0xf8,0x5f,0x02,0xa9,0xf6,0x57,0x03,0xa9};
    if (!np_mem_eq(np_at(RVA_PACER_THREAD), fp, sizeof(fp))) {
        NPLOG(@"❌ VSync 线程体指纹不匹配（二进制版本不同？）→ 跳过节拍补丁");
        return NO;
    }
    if (pacerHz <= 0) pacerHz = 60;
    uint32_t period = (uint32_t)(1000000u / (uint32_t)pacerHz);
    if (period < 1000)  period = 1000;
    if (period > 65000) period = 65000;

    uint32_t i0 = np_movz_w(24, (uint16_t)(period - 1));   // 追赶阈值 = period-1
    uint32_t i1 = np_movz_w(25, (uint16_t)period);         // VSync 周期(µs)
    uint32_t i2 = np_movn_x(26, (uint16_t)(period - 1));   // MOVN: X26 = -(period-1)-1 = -period

    uint32_t cur0 = np_rd32(gBase + RVA_PACER_MOV_W24);
    uint32_t cur1 = np_rd32(gBase + RVA_PACER_MOV_W25);
    uint32_t cur2 = np_rd32(gBase + RVA_PACER_MOVN_X26);
    uint32_t oldPeriod = (cur1 >> 5) & 0xFFFF;

    if (cur0 == i0 && cur1 == i1 && cur2 == i2) {
        NPLOG(@"[FPS] VSync 节拍已是 %uµs (%dHz)，无需补丁", period, pacerHz);
        return YES;
    }
    if (!NpPatchCode(np_at(RVA_PACER_MOV_W24), &i0, 4)) return NO;
    if (!NpPatchCode(np_at(RVA_PACER_MOV_W25), &i1, 4)) return NO;
    if (!NpPatchCode(np_at(RVA_PACER_MOVN_X26), &i2, 4)) return NO;

    uint32_t a0 = np_rd32(gBase + RVA_PACER_MOV_W24);
    uint32_t a1 = np_rd32(gBase + RVA_PACER_MOV_W25);
    uint32_t a2 = np_rd32(gBase + RVA_PACER_MOVN_X26);
    BOOL ok = (a0 == i0 && a1 == i1 && a2 == i2);
    NPLOG(@"%@ VSync 节拍补丁: %uµs → %uµs (%dHz)   [%08x %08x %08x → %08x %08x %08x]",
          ok ? @"✅" : @"⚠️", oldPeriod, period, pacerHz, cur0, cur1, cur2, a0, a1, a2);
    if (ok) NPLOG(@"   ↳ MOVZ W24,#%u  MOVZ W25,#%u  MOVN X26,#%u(=-%u)", period - 1, period, period - 1, period);
    return ok;
}

#pragma mark - ============================ Vulkan swapchain ============================

typedef int32_t (*VkCreateSwapchainFn)(void *device, void *createInfo, const void *alloc, void **out);
static VkCreateSwapchainFn gOrigVkCreateSwapchain = NULL;
static volatile int gSwapchainCount = 0;
static volatile uint32_t gLastOrigW = 0, gLastOrigH = 0, gLastNewW = 0, gLastNewH = 0;

static int32_t NpHook_vkCreateSwapchainKHR(void *device, void *createInfo, const void *alloc, void **out)
{
    if (!createInfo || !gCfg.enabled || gCfg.probe)
        return gOrigVkCreateSwapchain(device, createInfo, alloc, out);

    uint8_t copy[VKSCI_SIZE];
    memcpy(copy, createInfo, VKSCI_SIZE);
    uint8_t *ci = copy;

    uint32_t origCS    = *(uint32_t *)(ci + VKSCI_COLORSPACE);
    uint32_t origW     = *(uint32_t *)(ci + VKSCI_EXTENT);
    uint32_t origH     = *(uint32_t *)(ci + VKSCI_EXTENT + 4);
    uint32_t origUsage = *(uint32_t *)(ci + VKSCI_USAGE);
    uint32_t origAlpha = *(uint32_t *)(ci + VKSCI_COMPOSITE_ALPHA);
    uint32_t origPM    = *(uint32_t *)(ci + VKSCI_PRESENT_MODE);

    int tw = (int)origW, th = (int)origH;
    BOOL isNative = YES;
    NpDeriveExtent((int)origW, (int)origH, &tw, &th, &isNative);
    if (tw <= 0 || th <= 0) { tw = (int)origW & ~1; th = (int)origH & ~1; }

    *(uint32_t *)(ci + VKSCI_EXTENT)     = (uint32_t)tw;
    *(uint32_t *)(ci + VKSCI_EXTENT + 4) = (uint32_t)th;

    BOOL direct = NpDirectActive() && isNative;
    if (direct) {
        if (origAlpha != VK_COMPOSITE_ALPHA_OPAQUE_BIT)
            *(uint32_t *)(ci + VKSCI_COMPOSITE_ALPHA) = VK_COMPOSITE_ALPHA_OPAQUE_BIT;
        if (origCS != VK_COLOR_SPACE_SRGB)
            *(uint32_t *)(ci + VKSCI_COLORSPACE) = VK_COLOR_SPACE_SRGB;
        if (gCfg.directUsage)
            *(uint32_t *)(ci + VKSCI_USAGE) = VK_IMAGE_USAGE_COLOR_ATTACHMENT;
    }
    if (gCfg.noVsync)
        *(uint32_t *)(ci + VKSCI_PRESENT_MODE) = VK_PRESENT_MODE_IMMEDIATE;

    uint32_t newCS    = *(uint32_t *)(ci + VKSCI_COLORSPACE);
    uint32_t newUsage = *(uint32_t *)(ci + VKSCI_USAGE);
    uint32_t newAlpha = *(uint32_t *)(ci + VKSCI_COMPOSITE_ALPHA);
    uint32_t newPM    = *(uint32_t *)(ci + VKSCI_PRESENT_MODE);

    gLastOrigW = origW; gLastOrigH = origH; gLastNewW = (uint32_t)tw; gLastNewH = (uint32_t)th;

    int n = ++gSwapchainCount;
    if (n <= 8 || origW != (uint32_t)tw || origH != (uint32_t)th) {
        NPLOG(@"[SC] #%d 原始: extent=%ux%u colorspace=%u usage=0x%x alpha=%u presentMode=%u",
              n, origW, origH, origCS, origUsage, origAlpha, origPM);
        NPLOG(@"[SC] #%d 覆写: extent=%ux%u colorspace=%u usage=0x%x alpha=%u presentMode=%u   (direct=%d isNative=%d directUsage=%d noVsync=%d)",
              n, tw, th, newCS, newUsage, newAlpha, newPM, direct, isNative, gCfg.directUsage, gCfg.noVsync);
        NPLOG(@"[SC] 参考: presentMode 0=IMMEDIATE 2=FIFO | alpha 1=OPAQUE 8=INHERIT | usage 0x13=COLOR_ATTACH+TRANSFER_SRC/DST 0x10=仅COLOR_ATTACHMENT | colorspace 0=SRGB");
    }

    int32_t r = gOrigVkCreateSwapchain(device, copy, alloc, out);
    if (n <= 8) NPLOG(@"[SC] #%d 返回 VkResult=%d%@", n, r, (r == 0 ? @" (VK_SUCCESS)" : @""));
    return r;
}

#pragma mark - ============================ CAMetalLayer / UIScreen ============================

static volatile uint64_t gFrameCount = 0;
static volatile int      gLastDrawableW = 0, gLastDrawableH = 0;
static volatile int      gLayerOpaque = -1, gLayerFramebufferOnly = -1, gLayerDisplaySync = -1;
static volatile double   gLayerContentsScale = -1;

static BOOL NpSwizzle(Class cls, SEL sel, IMP imp, IMP *orig)
{
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { NPLOG(@"⚠️ 方法不存在，跳过: -[%@ %@]", cls, NSStringFromSelector(sel)); return NO; }
    if (orig) *orig = method_getImplementation(m);
    method_setImplementation(m, imp);
    return YES;
}

// 图层/屏幕几何快照 —— 判断 Composited 成因的关键证据
static void NpLogGeometry(CALayer *layer, const char *tag)
{
    @try {
        UIScreen *sc = [UIScreen mainScreen];
        CGRect nb = sc.nativeBounds, b = sc.bounds;
        NSInteger panelMax = 60;
        if ([sc respondsToSelector:@selector(maximumFramesPerSecond)]) panelMax = sc.maximumFramesPerSecond;
        NPLOG(@"[GEO/%s] screen: bounds=%.0fx%.0f pt  nativeBounds=%.0fx%.0f px  scale=%.2f nativeScale=%.2f maxFPS=%ld",
              tag, b.size.width, b.size.height, nb.size.width, nb.size.height, sc.scale, sc.nativeScale, (long)panelMax);

        if (layer) {
            CALayer *pres = layer.presentationLayer ?: layer;
            CGSize ds = CGSizeZero;
            BOOL fbOnly = NO;
            BOOL isMetal = [layer respondsToSelector:@selector(framebufferOnly)];
            if (isMetal) {
                ds = [(CAMetalLayer *)layer drawableSize];
                fbOnly = [(CAMetalLayer *)layer framebufferOnly];
            }
            NPLOG(@"[GEO/%s] layer: frame=(%.0f,%.0f %.0fx%.0f) bounds=%.0fx%.0f position=(%.0f,%.0f) anchor=(%.2f,%.2f) "
                  @"contentsScale=%.2f drawableSize=%.0fx%.0f gravity=%@ opaque=%d fbOnly=%d masksToBounds=%d sublayers=%lu",
                  tag, pres.frame.origin.x, pres.frame.origin.y, pres.frame.size.width, pres.frame.size.height,
                  pres.bounds.size.width, pres.bounds.size.height,
                  pres.position.x, pres.position.y, pres.anchorPoint.x, pres.anchorPoint.y,
                  pres.contentsScale, ds.width, ds.height,
                  pres.contentsGravity, pres.opaque, fbOnly, pres.masksToBounds,
                  (unsigned long)(pres.sublayers ? pres.sublayers.count : 0));
        }
    } @catch (NSException *e) {
        NPLOG(@"[GEO/%s] 快照异常: %@", tag, e.reason);
    }
}

static id (*orig_nextDrawable)(id, SEL);
static id Np_nextDrawable(id self, SEL _cmd)
{
    gFrameCount++;
    return orig_nextDrawable(self, _cmd);
}

static void (*orig_setDrawableSize)(id, SEL, CGSize);
static void Np_setDrawableSize(id self, SEL _cmd, CGSize sz)
{
    gLastDrawableW = (int)sz.width; gLastDrawableH = (int)sz.height;
    static int logged = 0;
    if (logged++ < 6) {
        NPLOG(@"[LAYER] setDrawableSize: %.0fx%.0f", sz.width, sz.height);
        if (logged == 1) NpLogGeometry((CALayer *)self, "首帧");
    }
    orig_setDrawableSize(self, _cmd, sz);
}

static void (*orig_setOpaque)(id, SEL, BOOL);
static void Np_setOpaque(id self, SEL _cmd, BOOL v)
{
    gLayerOpaque = v ? 1 : 0;
    if (NpDirectActive() && !v) {
        NPLOG(@"[LAYER] setOpaque:NO → 强制 YES（Direct 直写需要不透明）");
        v = YES;
    }
    orig_setOpaque(self, _cmd, v);
}

static void (*orig_setFramebufferOnly)(id, SEL, BOOL);
static void Np_setFramebufferOnly(id self, SEL _cmd, BOOL v)
{
    gLayerFramebufferOnly = v ? 1 : 0;
    if (NpDirectActive() && gCfg.directUsage && !v) {
        NPLOG(@"[LAYER] setFramebufferOnly:NO → 强制 YES（directUsage=true）");
        v = YES;
    }
    orig_setFramebufferOnly(self, _cmd, v);
}

static void (*orig_setDisplaySyncMVK)(id, SEL, BOOL);
static void Np_setDisplaySyncMVK(id self, SEL _cmd, BOOL v)
{
    gLayerDisplaySync = v ? 1 : 0;
    NPLOG(@"[LAYER] setDisplaySyncEnabledMVK:%d%@", v, (gCfg.noVsync ? @" → 强制 NO" : @""));
    if (gCfg.enabled && !gCfg.probe && gCfg.noVsync) v = NO;
    orig_setDisplaySyncMVK(self, _cmd, v);
}

static void (*orig_setContentsScale)(id, SEL, CGFloat);
static void Np_setContentsScale(id self, SEL _cmd, CGFloat s)
{
    gLayerContentsScale = (double)s;
    CGFloat want = s;
    if (NpDirectActive() && gCfg.forceContentsScale) {
        @try {
            CGFloat ns = [UIScreen mainScreen].nativeScale;
            if (ns > 0 && fabs(ns - s) > 0.001) {
                NPLOG(@"[LAYER] setContentsScale:%.2f → 强制 %.2f (= UIScreen.nativeScale)", (double)s, (double)ns);
                want = ns;
            }
        } @catch (NSException *e) { (void)e; }
    } else {
        static int logged = 0;
        if (logged++ < 3) NPLOG(@"[LAYER] setContentsScale:%.2f", (double)s);
    }
    orig_setContentsScale(self, _cmd, want);
}

static NSInteger (*orig_maxFPS)(id, SEL);
static NSInteger Np_maximumFramesPerSecond(id self, SEL _cmd)
{
    NSInteger v = orig_maxFPS(self, _cmd);
    static int logged = 0;
    if (logged++ < 3) NPLOG(@"[SCR] UIScreen.maximumFramesPerSecond = %ld", (long)v);
    return v;
}

#pragma mark - ============================ 配置应用 ============================

static void NpApplyConfig(BOOL firstTime)
{
    NpComputePlan();

    NPLOG(@"──────────── 应用配置 (%@) ────────────", firstTime ? @"首次" : @"热重载");
    NPLOG(@"开关①帧率  : frameRate=%d%@", gCfg.frameRate, (gCfg.frameRate <= 0 ? @" (不改)" : @""));
    if (gCfg.effFps > 0)
        NPLOG(@"             VSync 节拍 %dHz(%dµs) ÷ 分频器 %d → 目标 %d fps；引擎自身 fps 字节保持原值（逻辑步进不动）",
              gCfg.effPacerHz, 1000000 / gCfg.effPacerHz, gCfg.effDivisor, gCfg.effPacerHz / gCfg.effDivisor);

    const char *mode = (gCfg.resMode == NpResModeNative ? "native(不动 extent)"
                        : (gCfg.resMode == NpResModeScale ? "按引擎 extent × 比例" : "固定分辨率"));
    NPLOG(@"开关②分辨率: %s%@", mode, NpDirectActive() ? @"；直写友好模式=ON" : @"；直写友好模式=off");

    // ── 步进 / 时间基 / 时间流速预测（此处 gBase 已就绪，可安全读引擎内存） ──
    {
        uint8_t  liveByte = NpEngineFpsByte();
        uint32_t tbLive   = NpTimeBaseLive();
        uint32_t tb       = (gCfg.timeBase > 0) ? (uint32_t)gCfg.timeBase : tbLive;
        uint8_t  eb       = (liveByte > 0) ? liveByte : 30;             // 引擎未初始化时按 30 预估
        uint32_t step     = (eb > 0) ? (tb / eb) : 0;
        double   tick     = (gCfg.effPacerHz > 0 && gCfg.effDivisor > 0)
                            ? (double)gCfg.effPacerHz / (double)gCfg.effDivisor : 0;
        double   flowA    = tick * (double)step / (double)TIME_BASE_DEFAULT;  // 引擎另有固定 3000 实时基准
        double   flowB    = (eb > 0) ? tick / (double)eb : 0;                 // 该全局本身就是单位基准
        NPLOG(@"步进: 时间基=%u(实读 %u)  fps字节=%u(实读 %u) → 单帧 %u 单位 | 帧唤醒 %.0f 次/秒",
              tb, tbLive, eb, liveByte, step, tick);
        NPLOG(@"时间流速预测: 模型A(固定%u实时基准)=%.2fx   模型B(全局即单位基准)=%.2fx   ← 请与实测手感对照",
              TIME_BASE_DEFAULT, flowA, flowB);
        if (gCfg.effEngineFps > 0)
            NPLOG(@"ℹ️ 同时按 engineFps=%d 直写 fps 字节（引擎校验上限 60；写 >60 会进 3D 场景闪退）", gCfg.effEngineFps);
        if (gCfg.timeBase <= 0 && gCfg.frameRate > 30)
            NPLOG(@"💡 若模型A成立：把 timeBase 设为 %u（= %u×30÷%d）即可在 fps 字节不动的前提下把时间流速拉回 1.0×",
                  (unsigned)(TIME_BASE_DEFAULT * 30u / (unsigned)gCfg.frameRate), TIME_BASE_DEFAULT, gCfg.frameRate);
    }

    if (!gCfg.enabled) { NPLOG(@"enabled=false → 不介入（重启游戏可完全恢复）"); return; }
    if (gCfg.probe)    { NPLOG(@"probe=true → 只观察不修改"); return; }

    if (gCfg.effPacerHz > 0) NpApplyPacerPeriod(gCfg.effPacerHz);
    if (!gInitThunkHooked && gCfg.effDivisor > 0)
        NPLOG(@"ℹ️ Init thunk 未 hook → 分频器走轮询降级（1 秒粒度）");
    NpPollNuCCSys();
}

#pragma mark - ============================ 统计线程 ============================

static void *NpStatThread(void *arg)
{
    (void)arg;
    uint64_t frames = 0;
    NSTimeInterval lastT = [NSDate timeIntervalSinceReferenceDate];
    NSTimeInterval lastStat = lastT;
    BOOL geomLogged = NO;
    int ticks = 0;

    for (;;) {
        sleep(1);                                   // 1 秒轮询（兜底分频器/配置热重载）
        if (!gCfg.enabled) continue;
        ticks++;

        NpPollNuCCSys();

        // 首帧后的几何快照（主线程执行，避免 UIKit 线程问题）
        if (!geomLogged && ticks >= 2) {
            geomLogged = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    UIWindow *win = nil;
                    if (@available(iOS 13.0, *)) {
                        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                            if (![s isKindOfClass:[UIWindowScene class]]) continue;
                            for (UIWindow *w in ((UIWindowScene *)s).windows) {
                                if (w.isKeyWindow) { win = w; break; }
                            }
                            if (win) break;
                        }
                    }
                    if (!win) win = UIApplication.sharedApplication.keyWindow;
                    if (win)
                        NPLOG(@"[GEO/Win] keyWindow bounds=%.0fx%.0f pt scene=%@", win.bounds.size.width,
                              win.bounds.size.height, NSStringFromClass(win.windowScene.class) ?: @"-");
                    CALayer *root = win.layer;
                    if (root) NpLogGeometry(root, "window-root");
                } @catch (NSException *e) { (void)e; }
            });
        }

        if (ticks == 3 || ticks == 12) NpDumpPointers(ticks == 3 ? "3s" : "12s");

        if (gInitThunkCalls == 0 && gSwapchainCount > 0 && ticks == 5)
            NPLOG(@"ℹ️ 已创建 %d 个 swapchain，但 nummRender::Init(0x4C3BA0) 一次都没被调用 → 分频器改由轮询直写 nummRender+0x9C",
                  gSwapchainCount);

        int windowSec = (gCfg.statSeconds > 0) ? gCfg.statSeconds : 5;
        NSTimeInterval t = [NSDate timeIntervalSinceReferenceDate];
        if (t - lastStat < (double)windowSec) continue;

        uint64_t now = gFrameCount;
        double dt = t - lastStat;
        uint64_t delta = now - frames;
        double fps = (dt > 0.1) ? (double)delta / dt : 0.0;
        frames = now; lastStat = t;
        (void)lastT;

        uint8_t eb = NpEngineFpsByte();
        double predFlow = (eb > 0) ? (fps / (double)eb) : 0.0;
        NPLOG(@"[STAT] 时间流速预测 %.2fx (= 实测 %.1f fps ÷ 引擎字节 %u)   ← 与手感对照；不符请回传本行",
              predFlow, fps, eb);
        NPLOG(@"[STAT] 实测 %.1f fps (%llu 帧 / %.1fs) · drawableSize=%dx%d · layer(opaque=%d fbOnly=%d vsync=%d contentsScale=%.1f) · "
              @"分频器=%d 节拍=%dHz · 时间基=%u 引擎fps字节=%u(步进 %u 单位) · swapchain(原始 %ux%u → 覆写 %ux%u) · Init调用=%d SetFrameRate调用=%d",
              fps, (unsigned long long)delta, dt, gLastDrawableW, gLastDrawableH,
              gLayerOpaque, gLayerFramebufferOnly, gLayerDisplaySync, gLayerContentsScale,
              gCfg.effDivisor, gCfg.effPacerHz,
              NpTimeBaseLive(),
              NpEngineFpsByte(),
              (NpEngineFpsByte() ? NpTimeBaseLive() / NpEngineFpsByte() : 0),
              gLastOrigW, gLastOrigH, gLastNewW, gLastNewH,
              gInitThunkCalls, gSetFrameRateCalls);

        struct stat st;
        if (stat(NpCfgPath().fileSystemRepresentation, &st) == 0 && st.st_mtime != gCfgMTime) {
            NPLOG(@"🔄 检测到配置变更，重新加载（extent/节拍类改动建议重启游戏以完全生效）");
            NpConfigLoad();
            NpApplyConfig(NO);
        }
    }
    return NULL;
}

#pragma mark - ============================ 安装 ============================

static uintptr_t NpFindGameImage(char *outName, size_t outNameLen)
{
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, NP_TARGET_IMAGE_NAME) || strstr(name, ".dylib")) continue;
        const struct mach_header *h = _dyld_get_image_header(i);
        if (!h) continue;
        if (outName && outNameLen) strlcpy(outName, name, outNameLen);
        return (uintptr_t)h;
    }
    return 0;
}

static void NpInstall(void)
{
    NpLogOpen();
    NpConfigLoad();
    if (gCfg.captureStderr) NpRedirectStderr();

    NPLOG(@"══════════════════════════════════════════════");
    NPLOG(@"NarutoPlus v%@ — 帧率解锁 / 分辨率 / Direct 直写", NP_VERSION);
    NPLOG(@"日志: %@", NpLogPath());
    NPLOG(@"进程: %@ (pid %d)", NSProcessInfo.processInfo.processName, getpid());
    NPLOG(@"══════════════════════════════════════════════");

    char imgName[1024] = {0};
    gBase = NpFindGameImage(imgName, sizeof(imgName));
    if (!gBase) {
        NPLOG(@"ℹ️ 已加载映像中没有 %s —— 本补丁只在游戏进程生效，退出（不在宿主 App 内做任何事）",
              NP_TARGET_IMAGE_NAME);
        return;
    }
    NPLOG(@"✅ 目标映像: %@", [NSString stringWithUTF8String:imgName]);
    NPLOG(@"   加载基址: 0x%lx", (unsigned long)gBase);

    // ---- 指纹自检 ----
    static const uint8_t fpThunk[12]  = {0xe5,0x03,0x04,0xaa,0xe2,0x03,0x01,0xaa,0xe1,0x03,0x00,0xaa};
    static const uint8_t fpPacer[16]  = {0xfc,0x6f,0xba,0xa9,0xfa,0x67,0x01,0xa9,
                                         0xf8,0x5f,0x02,0xa9,0xf6,0x57,0x03,0xa9};
    static const uint8_t fpVkSw[16]   = {0xff,0x83,0x01,0xd1,0xfa,0x67,0x01,0xa9,
                                         0xf8,0x5f,0x02,0xa9,0xf6,0x57,0x03,0xa9};
    static const uint8_t fpSetFps[8]  = {0x01,0x4c,0x26,0x39,0x3f,0xf0,0x00,0x71};
    {
        BOOL okT = np_mem_eq(np_at(RVA_INIT_THUNK), fpThunk, sizeof(fpThunk));
        BOOL okP = np_mem_eq(np_at(RVA_PACER_THREAD), fpPacer, sizeof(fpPacer));
        BOOL okV = np_mem_eq(np_at(RVA_VK_CREATE_SWAPCHAIN), fpVkSw, sizeof(fpVkSw));
        BOOL okS = np_mem_eq(np_at(RVA_SET_FRAMERATE), fpSetFps, sizeof(fpSetFps));
        NPLOG(@"指纹自检: Init=%d Pacer=%d vkCreateSwapchain=%d SetFrameRate=%d  (全 1 = 匹配 1.0.1)",
              okT, okP, okV, okS);
        if (!(okT && okP && okV && okS))
            NPLOG(@"   原始字节: Init=[%@] Pacer=[%@]",
                  np_hexdump(np_at(RVA_INIT_THUNK), 12), np_hexdump(np_at(RVA_PACER_THREAD), 16));
    }

    BOOL hookOK = NpResolveHookEngine();

    if (hookOK && !gCfg.probe) {
        if (np_mem_eq(np_at(RVA_INIT_THUNK), fpThunk, sizeof(fpThunk))) {
            pMSHookFunction(np_at(RVA_INIT_THUNK), (void *)NpHook_InitThunk, (void **)&gOrigInitThunk);
            gInitThunkHooked = (gOrigInitThunk != NULL);
            NPLOG(@"%@ hook nummRender::Init 调用点 (trampoline=%p)", gInitThunkHooked ? @"✅" : @"❌",
                  (void *)gOrigInitThunk);
        } else {
            NPLOG(@"⚠️ Init thunk 指纹不匹配 → 跳过（分频器改动改走轮询）");
        }

        if (np_mem_eq(np_at(RVA_SET_FRAMERATE), fpSetFps, sizeof(fpSetFps))) {
            pMSHookFunction(np_at(RVA_SET_FRAMERATE), (void *)NpHook_SetFrameRate, (void **)&gOrigSetFrameRate);
            NPLOG(@"%@ hook nuccSys::SetFrameRate (仅记录)", gOrigSetFrameRate ? @"✅" : @"❌");
        }

        // 3-2. nuccSys::UpdateRenderExtent — 纠回 60/fps 造成的 0
        static const uint8_t fpUpdRe[16] = {0xe9,0x23,0xbc,0x6d,0xf6,0x57,0x01,0xa9,
                                            0xf4,0x4f,0x02,0xa9,0xfd,0x7b,0x03,0xa9};
        if (np_mem_eq(np_at(RVA_UPDATE_RENDER), fpUpdRe, sizeof(fpUpdRe))) {
            pMSHookFunction(np_at(RVA_UPDATE_RENDER), (void *)NpHook_UpdateRenderExtent, (void **)&gOrigUpdateRenderExtent);
            NPLOG(@"%@ hook nuccSys::UpdateRenderExtent (守卫 60/fps)", gOrigUpdateRenderExtent ? @"✅" : @"❌");
        } else {
            NPLOG(@"⚠️ UpdateRenderExtent 指纹不匹配 → 跳过守卫");
        }

        if (np_mem_eq(np_at(RVA_VK_CREATE_SWAPCHAIN), fpVkSw, sizeof(fpVkSw))) {
            pMSHookFunction(np_at(RVA_VK_CREATE_SWAPCHAIN), (void *)NpHook_vkCreateSwapchainKHR,
                            (void **)&gOrigVkCreateSwapchain);
            NPLOG(@"%@ hook vkCreateSwapchainKHR (分辨率 + 直写属性)", gOrigVkCreateSwapchain ? @"✅" : @"❌");
        } else {
            NPLOG(@"⚠️ vkCreateSwapchainKHR 指纹不匹配 → 跳过（分辨率改动失效）");
        }
    } else if (!hookOK) {
        NPLOG(@"❌ 未找到 MSHookFunction（ellekit 未加载？）→ 帧率走轮询降级，分辨率无法生效");
    }

    // ---- ObjC swizzle ----
    Class metalLayer = objc_getClass("CAMetalLayer");
    if (metalLayer) {
        int n = 0;
        n += NpSwizzle(metalLayer, @selector(nextDrawable),              (IMP)Np_nextDrawable,       (IMP *)&orig_nextDrawable);
        n += NpSwizzle(metalLayer, @selector(setDrawableSize:),          (IMP)Np_setDrawableSize,    (IMP *)&orig_setDrawableSize);
        n += NpSwizzle(metalLayer, @selector(setOpaque:),                (IMP)Np_setOpaque,          (IMP *)&orig_setOpaque);
        n += NpSwizzle(metalLayer, @selector(setFramebufferOnly:),       (IMP)Np_setFramebufferOnly, (IMP *)&orig_setFramebufferOnly);
        n += NpSwizzle(metalLayer, @selector(setDisplaySyncEnabledMVK:), (IMP)Np_setDisplaySyncMVK,  (IMP *)&orig_setDisplaySyncMVK);
        n += NpSwizzle(metalLayer, @selector(setContentsScale:),         (IMP)Np_setContentsScale,   (IMP *)&orig_setContentsScale);
        NPLOG(@"CAMetalLayer hooks: %d/6 安装完成", n);
    } else {
        NPLOG(@"⚠️ CAMetalLayer 类不存在（Metal 尚未加载）→ 图层修正/统计不可用");
    }
    Class uiScreen = objc_getClass("UIScreen");
    if (uiScreen) NpSwizzle(uiScreen, @selector(maximumFramesPerSecond), (IMP)Np_maximumFramesPerSecond, (IMP *)&orig_maxFPS);

    NpApplyConfig(YES);

    pthread_t th;
    pthread_attr_t at;
    pthread_attr_init(&at);
    pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
    if (pthread_create(&th, &at, NpStatThread, NULL) == 0) {
        pthread_setname_np("NarutoPlus-Stat");
        NPLOG(@"✅ 统计线程已启动（1 秒轮询；每 %d 秒一行 STAT）", gCfg.statSeconds);
    }
    pthread_attr_destroy(&at);

    NPLOG(@"安装流程结束 —— 若上面出现 ❌，STAT 行的实测 fps 会直接说明是否生效");
}

#pragma mark - ============================ 入口 ============================

__attribute__((constructor))
static void NarutoPlusInit(void)
{
    @try {
        NpInstall();
    } @catch (NSException *e) {
        NPLOG(@"❌ 安装异常: %@ %@", e.name, e.reason);
    }
}
