
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "SPCompat.h"
#import "SPLog.h"
#import "SPGesture.h"
#import "SPSettings.h"
#import "SPRepair.h"
#import "SPPaneController.h"

// 版本号从 dylib 所在包的 control 里读不到，这里直接把编译期版本写进常量，
// 由 build 脚本替换 __SP_VERSION__。找不到就退回 @"dev"。
static NSString *SPBundleVersion(void) {
    static NSString *v = nil;
    if (v) return v;
#ifdef SP_VERSION
    v = @SP_VERSION;
    return v;
#endif
    // 兜底：读 Info.plist
    NSDictionary *info = [[NSBundle bundleWithPath:@"/Library/MobileSubstrate/DynamicLibraries/SplitPane.plist"] infoDictionary];
    (void)info;
    v = @"dev";
    return v;
}


// ════════════════════════════════════════════════════════════════════════════
// 注入层。三条铁律（0.2.1 进安全模式就是踩了第一条）：
//  1) 不硬链接 libsubstrate，也绝不用 dlsym 去调 jbroot 这类 overloadable 私有符号。
//     dlsym 拿到的是 C 版 `const char*(const char*)`，按 NSString* 调 = 段错误。
//  2) constructor 只做「绝对安全」的三件事：写日志、dlsym MSHookMessageEx、
//     NSClassFromString 探测。不创建 UI、不碰 scene manager、不装手势。
//  3) 所有会碰 UIKit / SpringBoard 内部的动作，统一延后到场景就绪之后，每步独立 @try。
// ════════════════════════════════════════════════════════════════════════════

typedef void (*SPHookMsgExFn)(Class, SEL, IMP, IMP *);

// 判断触摸是否落在我们自己建的分屏窗口内。
// 落在里面 = 用户是在操作分屏 UI（×、交换、接缝、面板内容），
// 系统 home 手势这套逻辑必须完全让开，否则按钮收不到 touchUpInside
// （日志实证：点 × 时记到 pan up=-0 startY=9，全程没有一次 closeTapped）。
static BOOL SPPointInOurPaneWindow(CGPoint p) {
    @try {
        // 只要 SPWindowRegistry 里有活着的窗口，且这一点命中它，就让开。
        // 用登记表判断比猜类名可靠：所有自建窗口都在册。
        Class reg = NSClassFromString(@"SPWindowRegistry");
        if (!reg || ![reg respondsToSelector:NSSelectorFromString(@"count")]) return NO;
        NSUInteger n = ((NSUInteger (*)(id, SEL))objc_msgSend)(reg, NSSelectorFromString(@"count"));
        if (n == 0) return NO;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w.isHidden || w.alpha < 0.01) continue;
            CGPoint lp = [w convertPoint:p fromWindow:nil];
            if (!CGRectContainsPoint(w.bounds, lp)) continue;
            // 命中测试：这个点上有我们窗口的视图吗
            UIView *hit = [w hitTest:lp withEvent:nil];
            if (hit) return YES;
        }
    } @catch (__unused NSException *e) {}
    return NO;
}
static SPHookMsgExFn gHookMsgEx = NULL;

static IMP gOrigTouchesBegan = NULL;
static IMP gOrigTouchesEnded = NULL;
static IMP gOrigTouchesCancelled = NULL;
static IMP gOrigTouchesMoved = NULL;

void SPWriteEnvironmentProbe(void);
void SPProbeSwitcherAPI(void);
void SPProbeIconMenu(void);
void SPInstallIconMenuHook(void);
void SPInstallSceneForegroundHook(void);
void SPProbeForegroundAPI(void);

static void SPRepairCallback(CFNotificationCenterRef center, void *observer,
                             CFNotificationName name, const void *object, CFDictionaryRef info) {
    (void)center; (void)observer; (void)name; (void)object; (void)info;
    dispatch_async(dispatch_get_main_queue(), ^{
        SPLog(@"repair requested via darwin notify");
        // 这个通知是「卡住了」的自救通道：先把分屏强制关掉，再修 scene
        @try {
            SPLog(@"repair: force stop pane if active");
            [SPPaneController.shared stopWithCompletion:nil];
        } @catch (NSException *e) { SPLog(@"force stop ex %@", e.reason); }
        @try {
            for (UIWindow *w in [UIApplication sharedApplication].windows) {
                if (w.isHidden) continue;
                if (w.windowLevel > UIWindowLevelNormal && w.windowLevel < 100) {
                    w.hidden = YES;
                    w.rootViewController = nil;
                    w.windowScene = nil;
                    [w removeFromSuperview];
                }
            }
        } @catch (__unused NSException *e) {}
        @try { [SPRepair restoreAllScenes]; SPLog(@"repair done: %@", [SPRepair lastReport]); }
        @catch (NSException *e) { SPLog(@"repair ex %@", e.reason); }
    });
}

static void SPHookedTouchesBegan(id self, SEL _cmd, NSSet *touches, UIEvent *event) {
    if (gOrigTouchesBegan)
        ((void (*)(id, SEL, NSSet *, UIEvent *))gOrigTouchesBegan)(self, _cmd, touches, event);
    @try {
        if (![SPSettings enabled]) return;
        CGPoint p = CGPointZero;
        SEL loc = NSSelectorFromString(@"locationInView:");
        if ([self respondsToSelector:loc])
            p = ((CGPoint (*)(id, SEL, id))objc_msgSend)(self, loc, nil);
        // 分屏窗口内的触摸交给分屏自己处理，手势层完全不介入
        if (SPPointInOurPaneWindow(p)) { [[SPGesture shared] cancelTracking]; return; }
        [[SPGesture shared] handleHomePanBegan:p];
    } @catch (__unused NSException *e) {}
}

static void SPHookedTouchesEnded(id self, SEL _cmd, NSSet *touches, UIEvent *event) {
    @try {
        if ([SPSettings enabled]) {
            CGPoint lp = CGPointZero;
            SEL loc2 = NSSelectorFromString(@"locationInView:");
            if ([self respondsToSelector:loc2])
                lp = ((CGPoint (*)(id, SEL, id))objc_msgSend)(self, loc2, nil);
            if (SPPointInOurPaneWindow(lp)) {
                if (gOrigTouchesEnded)
                    ((void (*)(id, SEL, NSSet *, UIEvent *))gOrigTouchesEnded)(self, _cmd, touches, event);
                return;
            }
            CGPoint t = CGPointZero, v = CGPointZero;
            SEL tr = NSSelectorFromString(@"translationInView:");
            SEL ve = NSSelectorFromString(@"velocityInView:");
            if ([self respondsToSelector:tr])
                t = ((CGPoint (*)(id, SEL, id))objc_msgSend)(self, tr, nil);
            if ([self respondsToSelector:ve])
                v = ((CGPoint (*)(id, SEL, id))objc_msgSend)(self, ve, nil);
            [[SPGesture shared] consumeHomePan:nil translation:t velocity:v];
        }
    } @catch (__unused NSException *e) {}
    if (gOrigTouchesEnded)
        ((void (*)(id, SEL, NSSet *, UIEvent *))gOrigTouchesEnded)(self, _cmd, touches, event);
}

static void SPHookedTouchesMoved(id self, SEL _cmd, NSSet *touches, UIEvent *event) {
    if (gOrigTouchesMoved)
        ((void (*)(id, SEL, NSSet *, UIEvent *))gOrigTouchesMoved)(self, _cmd, touches, event);
    @try {
        if (![SPSettings enabled]) return;
        SEL loc = NSSelectorFromString(@"locationInView:");
        if ([self respondsToSelector:loc]) {
            CGPoint p = ((CGPoint (*)(id, SEL, id))objc_msgSend)(self, loc, nil);
            [[SPGesture shared] handleHomePanMoved:p];
        }
    } @catch (__unused NSException *e) {}
}

static void SPHookedTouchesCancelled(id self, SEL _cmd, NSSet *touches, UIEvent *event) {
    if (gOrigTouchesCancelled)
        ((void (*)(id, SEL, NSSet *, UIEvent *))gOrigTouchesCancelled)(self, _cmd, touches, event);
}

static BOOL SPInstallGestureHooks(void) {
    @try {
        Class cls = NSClassFromString(@"SBHomeGesturePanGestureRecognizer");
        if (!cls) { SPLog(@"hook: class missing"); return NO; }
        if (!gHookMsgEx) { SPLog(@"hook: MSHookMessageEx unavailable"); return NO; }
        gHookMsgEx(cls, NSSelectorFromString(@"touchesBegan:withEvent:"), (IMP)SPHookedTouchesBegan, &gOrigTouchesBegan);
        gHookMsgEx(cls, NSSelectorFromString(@"touchesEnded:withEvent:"), (IMP)SPHookedTouchesEnded, &gOrigTouchesEnded);
        gHookMsgEx(cls, NSSelectorFromString(@"touchesMoved:withEvent:"), (IMP)SPHookedTouchesMoved, &gOrigTouchesMoved);
        gHookMsgEx(cls, NSSelectorFromString(@"touchesCancelled:withEvent:"), (IMP)SPHookedTouchesCancelled, &gOrigTouchesCancelled);
        BOOL ok = (gOrigTouchesEnded != NULL);
        SPLog(@"hook: installed=%d began=%d ended=%d", ok, gOrigTouchesBegan != NULL, gOrigTouchesEnded != NULL);
        return ok;
    } @catch (NSException *e) {
        SPLog(@"hook: exception %@", e.reason);
        return NO;
    }
}

// 等 SpringBoard 真正就绪：必须有 UIApplication 实例 + 至少一个 window scene
static UIWindowScene *SPReadyScene(void) {
    @try {
        UIApplication *app = [UIApplication sharedApplication];
        if (!app) return nil;
        for (UIScene *s in app.connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]] &&
                s.activationState == UISceneActivationStateForegroundActive)
                return (UIWindowScene *)s;
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

static void SPBootstrapWhenReady(int tries) {
    if (tries <= 0) { SPLog(@"bootstrap: gave up waiting for scene"); return; }
    UIWindowScene *scene = SPReadyScene();
    if (!scene) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SPBootstrapWhenReady(tries - 1);
        });
        return;
    }
    SPLog(@"bootstrap: scene ready after waiting");

    @try { [SPSettings startObserving]; } @catch (NSException *e) { SPLog(@"prefs ex %@", e.reason); }
    @try { SPWriteEnvironmentProbe(); } @catch (NSException *e) { SPLog(@"probe ex %@", e.reason); }
    @try { SPProbeSwitcherAPI(); } @catch (NSException *e) { SPLog(@"probe ex %@", e.reason); }
    @try { SPProbeForegroundAPI(); } @catch (NSException *e) { SPLog(@"probe ex %@", e.reason); }
    @try { SPProbeIconMenu(); } @catch (NSException *e) { SPLog(@"probe ex %@", e.reason); }

    // 装图标长按菜单：这是现在唯一的分屏入口
    @try { SPInstallIconMenuHook(); } @catch (NSException *e) { SPLog(@"icon hook ex %@", e.reason); }

    BOOL hooked = NO;
    if ([SPSettings hooksEnabled]) hooked = SPInstallGestureHooks();
    else SPLog(@"hook: disabled by settings");
    [SPGesture shared].hooksAvailable = hooked;

    @try { [[SPGesture shared] installInWindowScene:scene]; }
    @catch (NSException *e) { SPLog(@"gesture install ex %@", e.reason); }

    if ([SPSettings bannerEnabled])
        @try {
            NSString *v = SPBundleVersion();
            SPShowLoadBanner([NSString stringWithFormat:@"SplitPane %@ 已加载%@", v,
                              hooked ? @"" : @" · 用状态栏双击"]);
        }
        @catch (NSException *e) { SPLog(@"banner ex %@", e.reason); }

    SPLog(@"bootstrap: done hooks=%d banner=%d", hooked, [SPSettings bannerEnabled]);
}

__attribute__((constructor)) static void SPSplitPaneInit(void) {
    @autoreleasepool {
        NSString *bid = nil;
        @try { bid = [[NSBundle mainBundle] bundleIdentifier]; } @catch (__unused NSException *e) {}
        SPLog(@"=== SplitPane %@ loaded (bundle=%@ pid=%d log=%@) ===",
              SPBundleVersion(),
              bid ?: @"?", getpid(), SPLogPath() ?: @"NSLog-only");
        if (![bid isEqualToString:@"com.apple.springboard"]) { SPLog(@"not springboard, idle"); return; }

        static char repairToken;
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        &repairToken, SPRepairCallback,
                                        CFSTR("com.seagull.splitpane.repair"),
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        @try { gHookMsgEx = (SPHookMsgExFn)dlsym(RTLD_DEFAULT, "MSHookMessageEx"); }
        @catch (__unused NSException *e) {}
        SPLog(@"dlsym MSHookMessageEx -> %p", gHookMsgEx);

        // 类存在性探测（纯字符串查找，绝对安全）
        @try {
            NSMutableArray *list = [NSMutableArray array];
            for (NSString *n in @[@"SBHomeGesturePanGestureRecognizer", @"SBSceneManagerCoordinator",
                                  @"SBApplicationController", @"SBSceneView", @"SBUIController",
                                  @"SBDeviceApplicationSceneHandle"]) {
                [list addObject:[NSString stringWithFormat:@"%@=%@", n,
                                 NSClassFromString(n) ? @"Y" : @"n"]];
            }
            SPLog(@"classes: %@", [list componentsJoinedByString:@" "]);
        } @catch (__unused NSException *e) {}

        // 其余全部延后，绝不在这里碰 UIKit
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SPBootstrapWhenReady(20);
        });
    }
}