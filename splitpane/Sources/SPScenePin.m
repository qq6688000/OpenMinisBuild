#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "SPCompat.h"
#import "SPLog.h"
#import "SPHost.h"

// ============================================================================
// 让分屏里的 App「无感交互」—— 点击不闪回桌面
//
// 现象（视频实证）：在分屏里点任意 App，画面跳回桌面再跳回来，一下一下闪。
// 原因：点 App 时系统把它的 FBScene 切成普通前台，分屏窗口被压到后台，
//       露出桌面；我们再把窗口拉回来 → 闪烁。
//
// 参考 InteractivePiP Duo 0.7.50（Sources/Tweak.x）：
//   hook -[FBScene updateSettings:withTransitionContext:(completion:)]
//   对「自己托管的 scene」把 settings 改成：
//       setForeground:YES
//       setBackgrounded:NO
//       setDeactivationReasons:0
//   这样系统想把 scene 切走时被我们改回前台，scene 始终留在分屏里。
//
// 注意：只动我们自己托管的 bundleID，其它 scene 一律原样放行，
//       绝不影响正常 App 切换与系统行为。
// ============================================================================

// 由 SPHost 维护：当前分屏里正在托管的 bundleID 集合
static NSMutableSet<NSString *> *SPHostedBundleIDs(void) {
    static NSMutableSet *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

void SPHostRegisterHostedBundleID(NSString *bundleID) {
    if (!bundleID.length) return;
    @synchronized (SPHostedBundleIDs()) { [SPHostedBundleIDs() addObject:bundleID]; }
}

void SPHostUnregisterHostedBundleID(NSString *bundleID) {
    if (!bundleID.length) return;
    @synchronized (SPHostedBundleIDs()) { [SPHostedBundleIDs() removeObject:bundleID]; }
}

void SPHostClearHostedBundleIDs(void) {
    @synchronized (SPHostedBundleIDs()) { [SPHostedBundleIDs() removeAllObjects]; }
}

static BOOL SPSceneIsHosted(id scene) {
    if (!scene) return NO;
    NSString *identifier = nil;
    // identifier 是公开属性；_identifier / sceneIdentifier 作兜底
    for (NSString *key in @[@"identifier", @"_identifier", @"sceneIdentifier"]) {
        SEL sel = NSSelectorFromString(key);
        if (![scene respondsToSelector:sel]) continue;
        @try {
            id v = ((id (*)(id, SEL))objc_msgSend)(scene, sel);
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) { identifier = v; break; }
        } @catch (__unused NSException *e) {}
    }
    if (!identifier.length) return NO;
    NSSet *hosted = nil;
    @synchronized (SPHostedBundleIDs()) { hosted = [SPHostedBundleIDs() copy]; }
    for (NSString *bid in hosted) {
        if ([identifier containsString:bid]) return YES;
    }
    return NO;
}

// 把 settings 改成「前台、不后台、无停用理由」
static id SPPinSceneForeground(id scene, id settings) {
    if (!settings || !SPSceneIsHosted(scene)) return settings;
    @try {
        id m = [settings respondsToSelector:@selector(mutableCopy)] ? [settings mutableCopy] : nil;
        if (!m) return settings;
        SEL s1 = NSSelectorFromString(@"setForeground:");
        if ([m respondsToSelector:s1]) ((void (*)(id, SEL, BOOL))objc_msgSend)(m, s1, YES);
        SEL s2 = NSSelectorFromString(@"setBackgrounded:");
        if ([m respondsToSelector:s2]) ((void (*)(id, SEL, BOOL))objc_msgSend)(m, s2, NO);
        SEL s3 = NSSelectorFromString(@"setDeactivationReasons:");
        if ([m respondsToSelector:s3]) ((void (*)(id, SEL, unsigned long long))objc_msgSend)(m, s3, 0ULL);
        return m;
    } @catch (NSException *e) {
        SPLog(@"pin scene ex %@", e.reason);
    }
    return settings;
}

// ---- hook ----

typedef void (*SPUpdateSettings3Fn)(id, SEL, id, id, id);
static SPUpdateSettings3Fn gOrigUS3 = NULL;
static void SPIUpdateSettings3(id self, SEL _cmd, id settings, id ctx, id completion) {
    id s = settings;
    @try { s = SPPinSceneForeground(self, settings); }
    @catch (__unused NSException *e) {}
    if (gOrigUS3) gOrigUS3(self, _cmd, s, ctx, completion);
}

typedef void (*SPUpdateSettings2Fn)(id, SEL, id, id);
static SPUpdateSettings2Fn gOrigUS2 = NULL;
static void SPIUpdateSettings2(id self, SEL _cmd, id settings, id ctx) {
    id s = settings;
    @try { s = SPPinSceneForeground(self, settings); }
    @catch (__unused NSException *e) {}
    if (gOrigUS2) gOrigUS2(self, _cmd, s, ctx);
}

typedef void (*SPHookMsgExFn)(Class, SEL, IMP, IMP *);

static BOOL SPTryHookFBScene(NSString *selName, IMP imp, IMP *orig) {
    Class cls = NSClassFromString(@"FBScene");
    if (!cls) { SPLog(@"fbs: FBScene 不存在"); return NO; }
    SEL sel = NSSelectorFromString(selName);
    if (![cls instancesRespondToSelector:sel]) return NO;
    SPHookMsgExFn hook = (SPHookMsgExFn)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (!hook) return NO;
    hook(cls, sel, imp, orig);
    return YES;
}

void SPInstallSceneForegroundHook(void) {
    int n = 0;
    n += SPTryHookFBScene(@"updateSettings:withTransitionContext:completion:",
                          (IMP)SPIUpdateSettings3, (IMP *)&gOrigUS3);
    n += SPTryHookFBScene(@"updateSettings:withTransitionContext:",
                          (IMP)SPIUpdateSettings2, (IMP *)&gOrigUS2);
    SPLog(@"fbs: updateSettings hooked %d/2 (3arg=%p 2arg=%p)", n,
          (void *)gOrigUS3, (void *)gOrigUS2);
}