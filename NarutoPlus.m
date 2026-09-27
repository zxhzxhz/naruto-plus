//
//  NarutoPlus.m — 火影忍者：究极忍者风暴+ (iOS/iPadOS)
//                帧率解锁 (30 → 120fps) + 渲染分辨率可控 + Direct 直写图层修正
//  ----------------------------------------------------------------------------
//  目标二进制 : narutoNext1 (v1.0.1, arm64 thin)  NUMM/nucc 引擎 + MoltenVK(Vulkan→Metal)
//  运行环境   : LiveContainer (ellekit / TweakLoader)，也兼容普通越狱注入
//  日志       : <guest Documents>/NarutoPlus.log
//  配置       : <guest Documents>/NarutoPlus.json （首次运行自动生成默认配置）
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
//          MOVN X26,#0x411A         @ +0x50   相位回退
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
//      Direct 条件：drawable == 屏幕原生像素 + 图层 opaque + framebufferOnly
//      + 非 EDR 色彩空间（无额外缩放/合成）。
//      控制点 = MoltenVK 的 swapchain 创建入参：
//      vkCreateSwapchainKHR(device, createInfo, alloc, out)    RVA 0x5D1504
//          imageColorSpace @+40   imageExtent @+44/+48   imageUsage @+56
//          compositeAlpha  @+84   presentMode @+88
//      （MoltenVK 内部 MVKSwapchain::init @0x65ED70 把这些字段直接喂给 CAMetalLayer）
//
//  ============================ 本补丁做什么 ============================
//      1. 代码补丁：VSync 节拍 16666µs → 1e6/目标Hz（120fps → 8333µs）
//      2. Hook nummRender::Init 调用点：按目标帧率改写 divisor（120fps → 1）
//      3. Hook vkCreateSwapchainKHR：强制 imageExtent = 配置分辨率；
//         原生分辨率时把 compositeAlpha/usage/colorspace 改成直写友好值
//      4. Hook CAMetalLayer：opaque/framebufferOnly/displaySync 修正 + 实时 FPS 统计
//      5. 全步骤日志 + 配置热重载（改完 JSON 等几秒生效）
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

#define NP_VERSION              @"1.0"
#define NP_LOG_FILENAME         @"NarutoPlus.log"
#define NP_CFG_FILENAME         @"NarutoPlus.json"
#define NP_LOG_MAX_BYTES        (12u * 1024u * 1024u)

#define NP_TARGET_IMAGE_NAME    "narutoNext1"

// ---- RVA（narutoNext1 1.0.1） ----
#define RVA_INIT_THUNK          0x4C3BA0u   // nummRender::Init 调用点
#define RVA_PACER_THREAD        0x4C6744u   // numm VSyncCallbackThread 线程体
#define RVA_PACER_MOV_W24       0x4C678Cu   // MOV  W24, #0x4119
#define RVA_PACER_MOV_W25       0x4C6790u   // MOV  W25, #0x411A
#define RVA_PACER_MOVN_X26      0x4C6794u   // MOVN X26, #0x411A
#define RVA_SET_FRAMERATE       0x4EA348u   // nuccSys::SetFrameRate
#define RVA_UPDATE_RENDER_EXT   0x4E9AE0u   // nuccSys::UpdateRenderExtent（文档用）
#define RVA_VK_CREATE_SWAPCHAIN 0x5D1504u   // vkCreateSwapchainKHR
#define RVA_MVK_SWAPCHAIN_INIT  0x65ED70u   // MVKSwapchain::init（文档用）
#define RVA_NUCCSYS_INSTANCE    0xFDEC00u   // qword_100FDEC00 = nuccSys 单例指针

// nuccSys 字段
#define OFF_NUCC_RENDER_W       1196u       // +0x4AC
#define OFF_NUCC_RENDER_H       1198u       // +0x4AE
#define OFF_NUCC_FPS_DIVISOR    1208u       // +0x4B8
#define OFF_NUCC_FPS_EFFECTIVE  2450u       // +0x992

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

#pragma mark - ============================ 配置 ============================

typedef enum { NpResModeNative = 0, NpResModeScale = 1, NpResModeFixed = 2 } NpResMode;

typedef struct {
    BOOL        enabled;
    BOOL        probe;          // 只观察不改
    int         frameRate;      // 0 = 不改；30 / 60 / 120
    int         pacerHz;        // 0 = 自动（= max(frameRate,60)，上限 120）
    int         logicFps;       // 0 = 与 frameRate 相同（分频器按它算）
    NpResMode   resMode;
    double      resScale;
    int         resW, resH;
    BOOL        forceDirect;
    BOOL        noVsync;
    BOOL        captureStderr;
    int         statSeconds;
    // 派生（由配置直接算出，不依赖 UIKit）
    int         effFps;
    int         effPacerHz;
    int         effDivisor;
} NpConfig;

static NpConfig  gCfg;
static NSString *gCfgPath = nil;
static time_t    gCfgMTime = 0;
static BOOL      gPollExtentWanted = NO;
static int       gPollExtentW = 0, gPollExtentH = 0;

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
        @"enabled"       : @YES,
        @"probe"         : @NO,
        @"frameRate"     : @120,          // 开关①：0=不改 / 30 / 60 / 120
        @"resolution"    : @"native",     // 开关②："native" | "1.0"/"0.75"(比例) | "1920x1080"
        @"pacerHz"       : @0,            // 0=自动（= max(frameRate,60)）
        @"logicFps"      : @0,            // 0=与 frameRate 一致
        @"forceDirect"   : @YES,          // 原生分辨率时修正为直写友好图层属性
        @"noVsync"       : @NO,           // true = presentMode 改 IMMEDIATE（可能撕裂）
        @"captureStderr" : @YES,
        @"statSeconds"   : @5
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
    gCfg.enabled       = YES;
    gCfg.frameRate     = 120;
    gCfg.resMode       = NpResModeNative;
    gCfg.resScale      = 1.0;
    gCfg.forceDirect   = YES;
    gCfg.captureStderr = YES;
    gCfg.statSeconds   = 5;
}

// 帧率规划：只用配置算术，不需要 UIKit ⇒ 可在 constructor 里立即算好
static void NpComputePlan(void)
{
    if (gCfg.frameRate <= 0) {
        gCfg.effFps = 0; gCfg.effPacerHz = 0; gCfg.effDivisor = 0;
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
}

static void NpConfigLoad(void)
{
    NSString *path = NpCfgPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) == 0) gCfgMTime = st.st_mtime;

    if (![fm fileExistsAtPath:path]) {
        NpConfigDefaults();
        NSData *d = [NSJSONSerialization dataWithJSONObject:NpCfgDefaultJSON()
                                                   options:NSJSONWritingPrettyPrinted error:NULL];
        if (d) [d writeToFile:path atomically:YES];
        NPLOG(@"未找到配置，已生成默认配置: %@", path);
        NpComputePlan();
        return;
    }

    NSData *d = [NSData dataWithContentsOfFile:path];
    id obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
    if (![obj isKindOfClass:[NSDictionary class]]) {
        NPLOG(@"⚠️ 配置解析失败（沿用默认值）: %@", path);
        NpConfigDefaults();
        NpComputePlan();
        return;
    }
    NSDictionary *j = (NSDictionary *)obj;
    NpConfigDefaults();

    if (j[@"enabled"])       gCfg.enabled       = [j[@"enabled"] boolValue];
    if (j[@"probe"])         gCfg.probe         = [j[@"probe"] boolValue];
    if (j[@"frameRate"])     gCfg.frameRate     = [j[@"frameRate"] intValue];
    if (j[@"pacerHz"])       gCfg.pacerHz       = [j[@"pacerHz"] intValue];
    if (j[@"logicFps"])      gCfg.logicFps      = [j[@"logicFps"] intValue];
    if (j[@"forceDirect"])   gCfg.forceDirect   = [j[@"forceDirect"] boolValue];
    if (j[@"noVsync"])       gCfg.noVsync       = [j[@"noVsync"] boolValue];
    if (j[@"captureStderr"]) gCfg.captureStderr = [j[@"captureStderr"] boolValue];
    if (j[@"statSeconds"])   gCfg.statSeconds   = [j[@"statSeconds"] intValue];
    if (j[@"resolution"])    gCfg.resScale      = NpParseResolution(j[@"resolution"], &gCfg.resMode,
                                                                    &gCfg.resW, &gCfg.resH);

    if (gCfg.statSeconds < 1)  gCfg.statSeconds = 1;
    if (gCfg.statSeconds > 60) gCfg.statSeconds = 60;

    NpComputePlan();

    NPLOG(@"配置: enabled=%d probe=%d frameRate=%d resolution=%@ forceDirect=%d noVsync=%d pacerHz=%d logicFps=%d",
          gCfg.enabled, gCfg.probe, gCfg.frameRate,
          (gCfg.resMode == NpResModeNative ? @"native"
             : (gCfg.resMode == NpResModeScale ? [NSString stringWithFormat:@"scale %.3f", gCfg.resScale]
                                               : [NSString stringWithFormat:@"%dx%d", gCfg.resW, gCfg.resH])),
          gCfg.forceDirect, gCfg.noVsync, gCfg.pacerHz, gCfg.logicFps);
}

#pragma mark - ============================ 屏幕尺寸（懒查询） ============================

static int gNativeW = 0, gNativeH = 0;   // 屏幕原生像素（横屏取向：W >= H）
static NSTimeInterval gBootTs = 0;

static void NpRefreshScreenSize(void)
{
    if (gNativeW > 0) return;
    if (gBootTs > 0 && [NSDate timeIntervalSinceReferenceDate] < gBootTs + 0.15) return;   // 太早不碰 UIKit
    @try {
        CGRect nb = [UIScreen mainScreen].nativeBounds;
        if (nb.size.width <= 0 || nb.size.height <= 0) return;
        gNativeW = (int)llround(MAX(nb.size.width, nb.size.height));
        gNativeH = (int)llround(MIN(nb.size.width, nb.size.height));
    } @catch (NSException *e) {
        NPLOG(@"⚠️ 查询 UIScreen.nativeBounds 异常: %@", e.reason);
    }
}

// 按“引擎原始 extent 的取向”输出目标分辨率；origPortrait = 原始是竖的
static void NpTargetExtentOriented(BOOL haveOrig, BOOL origPortrait, int *outW, int *outH)
{
    NpRefreshScreenSize();

    if (gNativeW <= 0) {                 // 还没拿到屏幕信息 → 保持引擎原值
        return;
    }

    int w = gNativeW, h = gNativeH;
    if (gCfg.resMode == NpResModeScale && gCfg.resScale > 0) {
        w = (int)llround(gNativeW * gCfg.resScale);
        h = (int)llround(gNativeH * gCfg.resScale);
    } else if (gCfg.resMode == NpResModeFixed && gCfg.resW > 0 && gCfg.resH > 0) {
        w = gCfg.resW; h = gCfg.resH;
        if (h > w) { int t = w; w = h; h = t; }
    }

    if (w < 320)   w = 320;
    if (h < 240)   h = 240;
    if (w > 16384) w = 16384;
    if (h > 16384) h = 16384;

    if (haveOrig && origPortrait) { int t = w; w = h; h = t; }
    *outW = w & ~1;
    *outH = h & ~1;
}

static void NpTargetExtent(int *outW, int *outH)
{
    int w = 0, h = 0;
    NpTargetExtentOriented(NO, NO, &w, &h);
    if (w <= 0 || h <= 0) { NpRefreshScreenSize(); w = gNativeW; h = gNativeH; }
    if (w <= 0) { w = 1920; h = 1080; }
    *outW = w; *outH = h;
}

static BOOL NpIsNativeResolution(void)
{
    if (gNativeW <= 0) return NO;
    int w, h; NpTargetExtent(&w, &h);
    return (MAX(w, h) == MAX(gNativeW, gNativeH) && MIN(w, h) == MIN(gNativeW, gNativeH));
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

#pragma mark - ============================ 帧率 ============================

typedef int64_t (*InitThunkFn)(int16_t w, int16_t h, uint32_t preset, uint32_t flags, uint32_t divisor);
static InitThunkFn gOrigInitThunk = NULL;
static BOOL        gInitThunkHooked = NO;

typedef int64_t (*SetFrameRateFn)(uintptr_t self, uint32_t fps);
static SetFrameRateFn gOrigSetFrameRate = NULL;

static int64_t NpHook_InitThunk(int16_t w, int16_t h, uint32_t preset, uint32_t flags, uint32_t divisor)
{
    if (!gCfg.enabled || gCfg.probe)
        return gOrigInitThunk(w, h, preset, flags, divisor);

    int tw = w, th = h;
    NpTargetExtentOriented(YES, (h > w), &tw, &th);
    if (tw <= 0 || th <= 0) { tw = w; th = h; }

    uint32_t nd = (gCfg.effDivisor > 0) ? (uint32_t)gCfg.effDivisor : divisor;

    NPLOG(@"[INIT] nummRender::Init 引擎入参 w=%d h=%d preset=%u flags=0x%x divisor=%u  →  改写 w=%d h=%d divisor=%u  (目标 %dfps / 节拍 %dHz)",
          w, h, preset, flags, divisor, tw, th, nd, gCfg.effFps, gCfg.effPacerHz);

    return gOrigInitThunk((int16_t)tw, (int16_t)th, preset, flags, nd);
}

static int64_t NpHook_SetFrameRate(uintptr_t self, uint32_t fps)
{
    NPLOG(@"[FPS] 游戏调用 nuccSys::SetFrameRate(%u)  (仅记录；分频器由本补丁在 Init 阶段覆盖)", fps);
    return gOrigSetFrameRate(self, fps);
}

// hook 不可用时的降级通道：直接写 nuccSys 实例字段
static void NpPollNuCCSys(void)
{
    if (!gBase) return;
    uintptr_t inst = *(volatile uintptr_t *)(gBase + RVA_NUCCSYS_INSTANCE);
    if (!inst || inst < 0x100000000ULL) return;

    uint8_t fps = *(volatile uint8_t *)(inst + OFF_NUCC_FPS_EFFECTIVE);
    if (fps == 0) return;                                  // 尚未初始化

    if (gCfg.effDivisor > 0) {
        uint32_t div = *(volatile uint32_t *)(inst + OFF_NUCC_FPS_DIVISOR);
        if (div != (uint32_t)gCfg.effDivisor) {
            np_wr32(inst + OFF_NUCC_FPS_DIVISOR, (uint32_t)gCfg.effDivisor);
            NPLOG(@"[FPS] (轮询) nuccSys+0x4B8 分频器 %u → %d", div, gCfg.effDivisor);
        }
    }
    if (gPollExtentWanted) {
        uint16_t w = np_rd16(inst + OFF_NUCC_RENDER_W);
        uint16_t h = np_rd16(inst + OFF_NUCC_RENDER_H);
        if (w != (uint16_t)gPollExtentW || h != (uint16_t)gPollExtentH) {
            np_wr16(inst + OFF_NUCC_RENDER_W, (uint16_t)gPollExtentW);
            np_wr16(inst + OFF_NUCC_RENDER_H, (uint16_t)gPollExtentH);
            NPLOG(@"[RES] (轮询) nuccSys 渲染尺寸 %ux%u → %dx%d", w, h, gPollExtentW, gPollExtentH);
        }
    }
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
    NpTargetExtentOriented((origW > 0 && origH > 0), (origH > origW), &tw, &th);
    if (tw <= 0 || th <= 0) { tw = (int)origW; th = (int)origH; }
    if (tw <= 0 || th <= 0) { tw = 1920; th = 1080; }

    *(uint32_t *)(ci + VKSCI_EXTENT)     = (uint32_t)tw;
    *(uint32_t *)(ci + VKSCI_EXTENT + 4) = (uint32_t)th;

    BOOL direct = NO;
    if (gCfg.forceDirect && NpIsNativeResolution()) {
        direct = YES;
        *(uint32_t *)(ci + VKSCI_COMPOSITE_ALPHA) = VK_COMPOSITE_ALPHA_OPAQUE_BIT;
        *(uint32_t *)(ci + VKSCI_COLORSPACE)      = VK_COLOR_SPACE_SRGB;
        *(uint32_t *)(ci + VKSCI_USAGE)           = VK_IMAGE_USAGE_COLOR_ATTACHMENT;
    }
    if (gCfg.noVsync)
        *(uint32_t *)(ci + VKSCI_PRESENT_MODE) = VK_PRESENT_MODE_IMMEDIATE;

    uint32_t newCS    = *(uint32_t *)(ci + VKSCI_COLORSPACE);
    uint32_t newUsage = *(uint32_t *)(ci + VKSCI_USAGE);
    uint32_t newAlpha = *(uint32_t *)(ci + VKSCI_COMPOSITE_ALPHA);
    uint32_t newPM    = *(uint32_t *)(ci + VKSCI_PRESENT_MODE);

    int n = ++gSwapchainCount;
    if (n <= 8 || origW != (uint32_t)tw || origH != (uint32_t)th) {
        NPLOG(@"[SC] #%d vkCreateSwapchainKHR 原始: extent=%ux%u colorspace=%u usage=0x%x alpha=%u presentMode=%u",
              n, origW, origH, origCS, origUsage, origAlpha, origPM);
        NPLOG(@"[SC] #%d 覆写后: extent=%ux%u colorspace=%u usage=0x%x alpha=%u presentMode=%u   (直写目标=%d noVsync=%d)",
              n, tw, th, newCS, newUsage, newAlpha, newPM, direct, gCfg.noVsync);
        NPLOG(@"[SC] 参考: presentMode 0=IMMEDIATE 1=MAILBOX 2=FIFO(vsync) | alpha 1=OPAQUE | usage 0x10=COLOR_ATTACHMENT | colorspace 0=SRGB");
    }

    int32_t r = gOrigVkCreateSwapchain(device, copy, alloc, out);
    if (n <= 8) NPLOG(@"[SC] #%d 返回 VkResult=%d%s", n, r, (r == 0 ? @" (VK_SUCCESS)" : @""));
    return r;
}

#pragma mark - ============================ CAMetalLayer / UIScreen ============================

static volatile uint64_t gFrameCount = 0;
static volatile int      gLastDrawableW = 0, gLastDrawableH = 0;
static volatile int      gLayerOpaque = -1, gLayerFramebufferOnly = -1, gLayerDisplaySync = -1;

static BOOL NpSwizzle(Class cls, SEL sel, IMP imp, IMP *orig)
{
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { NPLOG(@"⚠️ 方法不存在，跳过: -[%@ %@]", cls, NSStringFromSelector(sel)); return NO; }
    if (orig) *orig = method_getImplementation(m);
    method_setImplementation(m, imp);
    return YES;
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
    if (logged++ < 6)
        NPLOG(@"[LAYER] setDrawableSize: %.0fx%.0f   (屏幕原生 %dx%d)", sz.width, sz.height, gNativeW, gNativeH);
    orig_setDrawableSize(self, _cmd, sz);
}

static void (*orig_setOpaque)(id, SEL, BOOL);
static void Np_setOpaque(id self, SEL _cmd, BOOL v)
{
    gLayerOpaque = v ? 1 : 0;
    if (gCfg.enabled && !gCfg.probe && gCfg.forceDirect && NpIsNativeResolution() && !v) {
        NPLOG(@"[LAYER] setOpaque:NO → 强制 YES（Direct 直写需要不透明）");
        v = YES;
    }
    orig_setOpaque(self, _cmd, v);
}

static void (*orig_setFramebufferOnly)(id, SEL, BOOL);
static void Np_setFramebufferOnly(id self, SEL _cmd, BOOL v)
{
    gLayerFramebufferOnly = v ? 1 : 0;
    if (gCfg.enabled && !gCfg.probe && gCfg.forceDirect && NpIsNativeResolution() && !v) {
        NPLOG(@"[LAYER] setFramebufferOnly:NO → 强制 YES（避免被合成器读回）");
        v = YES;
    }
    orig_setFramebufferOnly(self, _cmd, v);
}

static void (*orig_setDisplaySyncMVK)(id, SEL, BOOL);
static void Np_setDisplaySyncMVK(id self, SEL _cmd, BOOL v)
{
    gLayerDisplaySync = v ? 1 : 0;
    NPLOG(@"[LAYER] setDisplaySyncEnabledMVK:%d%s", v, (gCfg.noVsync ? @" → 强制 NO" : @""));
    if (gCfg.enabled && !gCfg.probe && gCfg.noVsync) v = NO;
    orig_setDisplaySyncMVK(self, _cmd, v);
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
    NpRefreshScreenSize();

    int tw, th; NpTargetExtent(&tw, &th);
    gPollExtentW  = tw;
    gPollExtentH  = th;
    gPollExtentWanted = (gCfg.enabled && !gCfg.probe && gCfg.resMode != NpResModeNative);

    NPLOG(@"──────────── 应用配置 (%@) ────────────", firstTime ? @"首次" : @"热重载");
    NPLOG(@"开关①帧率  : frameRate=%d%@", gCfg.frameRate, (gCfg.frameRate <= 0 ? @" (不改)" : @""));
    if (gCfg.effFps > 0)
        NPLOG(@"             VSync 节拍 %dHz(%dµs) ÷ 分频器 %d → 目标 %d fps；引擎自身 fps 字节保持原值（逻辑步进不动）",
              gCfg.effPacerHz, 1000000 / gCfg.effPacerHz, gCfg.effDivisor, gCfg.effPacerHz / gCfg.effDivisor);
    NPLOG(@"开关②分辨率: %@ → 渲染 %dx%d%s",
          (gCfg.resMode == NpResModeNative ? @"native"
             : (gCfg.resMode == NpResModeScale ? [NSString stringWithFormat:@"比例 %.3f", gCfg.resScale]
                                               : [NSString stringWithFormat:@"固定 %dx%d", gCfg.resW, gCfg.resH])),
          tw, th,
          (gNativeW <= 0 ? @"  (屏幕信息未就绪，等首帧后再判定)"
                         : (NpIsNativeResolution() ? @"  = 原生像素 → 期望 Metal HUD 显示 Direct"
                                                   : @"  ≠ 原生像素 → Metal HUD 会显示 Composited")));

    if (!gCfg.enabled) { NPLOG(@"enabled=false → 不介入（重启游戏可完全恢复）"); return; }
    if (gCfg.probe)    { NPLOG(@"probe=true → 只观察不修改"); return; }

    if (gCfg.effPacerHz > 0) NpApplyPacerPeriod(gCfg.effPacerHz);
    if (!gInitThunkHooked && gCfg.effDivisor > 0)
        NPLOG(@"ℹ️ Init thunk 未 hook → 分频器走轮询降级（首个 swapchain 可能仍是旧值）");
    NpPollNuCCSys();
}

#pragma mark - ============================ 统计线程 ============================

static void *NpStatThread(void *arg)
{
    (void)arg;
    uint64_t frames = 0;
    NSTimeInterval lastT = [NSDate timeIntervalSinceReferenceDate];
    BOOL firstPass = YES;

    for (;;) {
        int win = (gCfg.statSeconds > 0) ? gCfg.statSeconds : 5;
        sleep((unsigned)win);
        if (!gCfg.enabled) continue;

        uint64_t now = gFrameCount;
        NSTimeInterval t = [NSDate timeIntervalSinceReferenceDate];
        double dt = t - lastT;
        uint64_t delta = now - frames;
        double fps = (dt > 0.1) ? (double)delta / dt : 0.0;
        frames = now; lastT = t;

        if (firstPass) {
            firstPass = NO;
            NpRefreshScreenSize();
            NSInteger panelMax = 0;
            @try {
                UIScreen *sc = [UIScreen mainScreen];
                if ([sc respondsToSelector:@selector(maximumFramesPerSecond)]) panelMax = sc.maximumFramesPerSecond;
            } @catch (NSException *e) { (void)e; }
            NPLOG(@"环境: %@ / iOS %@   面板最大刷新率 %ldHz   nativeBounds %dx%d px   bundle=%@",
                  UIDevice.currentDevice.model, UIDevice.currentDevice.systemVersion,
                  (long)panelMax, gNativeW, gNativeH, [NSBundle mainBundle].bundleIdentifier);
            if (panelMax > 0 && gCfg.effPacerHz > panelMax)
                NPLOG(@"⚠️ 目标节拍 %dHz 高于面板 %ldHz —— 本机物理上限就是 %ldfps，多余的帧会被丢",
                      gCfg.effPacerHz, (long)panelMax, (long)panelMax);
        }

        NPLOG(@"[STAT] 实测 %.1f fps (%llu 帧 / %.1fs) · drawableSize=%dx%d · layer(opaque=%d fbOnly=%d vsync=%d) · 分频器=%d 节拍=%dHz · %@",
              fps, (unsigned long long)delta, dt, gLastDrawableW, gLastDrawableH,
              gLayerOpaque, gLayerFramebufferOnly, gLayerDisplaySync,
              gCfg.effDivisor, gCfg.effPacerHz,
              (gNativeW <= 0 ? @"?" : (NpIsNativeResolution() ? @"原生分辨率" : @"缩放分辨率")));

        NpPollNuCCSys();

        struct stat st;
        if (stat(NpCfgPath().fileSystemRepresentation, &st) == 0 && st.st_mtime != gCfgMTime) {
            NPLOG(@"🔄 检测到配置变更，重新加载（分辨率/节拍类改动建议重启游戏以完全生效）");
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
    gLogFD = -1; gLogReady = NO;
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
    NPLOG(@"✅ 目标映像: %s", imgName);
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
            NPLOG(@"   原始字节: Init=[%@] Pacer=[%@]", np_hexdump(np_at(RVA_INIT_THUNK), 12),
                  np_hexdump(np_at(RVA_PACER_THREAD), 16));
    }

    BOOL hookOK = NpResolveHookEngine();

    if (hookOK && !gCfg.probe) {
        if (np_mem_eq(np_at(RVA_INIT_THUNK), fpThunk, sizeof(fpThunk))) {
            pMSHookFunction(np_at(RVA_INIT_THUNK), (void *)NpHook_InitThunk, (void **)&gOrigInitThunk);
            gInitThunkHooked = (gOrigInitThunk != NULL);
            NPLOG(@"%@ hook nummRender::Init 调用点 (trampoline=%p)", gInitThunkHooked ? @"✅" : @"❌",
                  (void *)gOrigInitThunk);
        } else {
            NPLOG(@"⚠️ Init thunk 指纹不匹配 → 跳过（分频器改动失效）");
        }

        if (np_mem_eq(np_at(RVA_SET_FRAMERATE), fpSetFps, sizeof(fpSetFps))) {
            pMSHookFunction(np_at(RVA_SET_FRAMERATE), (void *)NpHook_SetFrameRate, (void **)&gOrigSetFrameRate);
            NPLOG(@"%@ hook nuccSys::SetFrameRate (仅记录)", gOrigSetFrameRate ? @"✅" : @"❌");
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
        n += NpSwizzle(metalLayer, @selector(nextDrawable),             (IMP)Np_nextDrawable,       (IMP *)&orig_nextDrawable);
        n += NpSwizzle(metalLayer, @selector(setDrawableSize:),         (IMP)Np_setDrawableSize,    (IMP *)&orig_setDrawableSize);
        n += NpSwizzle(metalLayer, @selector(setOpaque:),               (IMP)Np_setOpaque,          (IMP *)&orig_setOpaque);
        n += NpSwizzle(metalLayer, @selector(setFramebufferOnly:),      (IMP)Np_setFramebufferOnly, (IMP *)&orig_setFramebufferOnly);
        n += NpSwizzle(metalLayer, @selector(setDisplaySyncEnabledMVK:), (IMP)Np_setDisplaySyncMVK, (IMP *)&orig_setDisplaySyncMVK);
        NPLOG(@"CAMetalLayer hooks: %d/5 安装完成", n);
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
        NPLOG(@"✅ 统计线程已启动（每 %d 秒一行 STAT）", gCfg.statSeconds);
    }
    pthread_attr_destroy(&at);

    NPLOG(@"安装流程结束 —— 若上面出现 ❌，STAT 行的实测 fps 会直接说明是否生效");
}

#pragma mark - ============================ 入口 ============================

__attribute__((constructor))
static void NarutoPlusInit(void)
{
    gBootTs = [NSDate timeIntervalSinceReferenceDate];
    NpLogOpen();
    NpLog(@"── NarutoPlus 载入 (constructor) ──");
    @try {
        NpInstall();
    } @catch (NSException *e) {
        NPLOG(@"❌ 安装异常: %@ %@", e.name, e.reason);
    }
}
