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

// 以 scene 实例 + 弱 owner token 登记：同 bundle 的新宿主不能被旧 detach 注销。
// 弱 key/owner 避免退出遗漏时注册表反过来延长 scene / host 的生命周期。
static NSMapTable *SPHostedScenes(void) {
    static NSMapTable *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality
                                   valueOptions:NSPointerFunctionsStrongMemory];
    });
    return map;
}

void SPHostRegisterHostedScene(id scene, id owner) {
    if (!scene || !owner) return;
    NSMapTable *map = SPHostedScenes();
    @synchronized (map) {
        NSHashTable *owners = [map objectForKey:scene];
        if (!owners) {
            owners = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
            [map setObject:owners forKey:scene];
        }
        [owners addObject:owner];
    }
}

void SPHostUnregisterHostedScene(id scene, id owner) {
    if (!scene || !owner) return;
    NSMapTable *map = SPHostedScenes();
    @synchronized (map) {
        NSHashTable *owners = [map objectForKey:scene];
        [owners removeObject:owner];
        if (!owners.allObjects.count) [map removeObjectForKey:scene];
    }
}

void SPHostClearHostedBundleIDs(void) {
    NSMapTable *map = SPHostedScenes();
    @synchronized (map) { [map removeAllObjects]; }
}

BOOL SPHostSceneIsHosted(id scene) {
    if (!scene) return NO;
    NSMapTable *map = SPHostedScenes();
    @synchronized (map) {
        NSHashTable *owners = [map objectForKey:scene];
        BOOL hosted = owners.allObjects.count > 0;
        if (!hosted) [map removeObjectForKey:scene];
        return hosted;
    }
}

// 只识别登记表用于诊断，不强行把 scene 推回前台。
// 强写 foreground/backgrounded 会和系统转场争抢，产生闪回与抖动；分屏窗口层级与宿主视图本地布局已足够保持呈现。
static id SPPinSceneForeground(id scene, id settings) {
    (void)scene;
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
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    NSUInteger count = [selName hasSuffix:@"completion:"] ? 5 : 4;
    if (sig.numberOfArguments != count || !SPType(sig.methodReturnType, "v")) return NO;
    for (NSUInteger i = 2; i < count; i++)
        if (!SPType([sig getArgumentTypeAtIndex:i], "@")) return NO;
    SPHookMsgExFn hook = (SPHookMsgExFn)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
    if (!hook) return NO;
    hook(cls, sel, imp, orig);
    return YES;
}

void SPInstallSceneForegroundHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        int n = 0;
        n += SPTryHookFBScene(@"updateSettings:withTransitionContext:completion:",
                              (IMP)SPIUpdateSettings3, (IMP *)&gOrigUS3);
        n += SPTryHookFBScene(@"updateSettings:withTransitionContext:",
                              (IMP)SPIUpdateSettings2, (IMP *)&gOrigUS2);
        SPLog(@"fbs: updateSettings hooked %d/2 (3arg=%p 2arg=%p)", n,
              (void *)gOrigUS3, (void *)gOrigUS2);
    });
}