#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "SPCompat.h"
#import "SPLog.h"
#import "SPGesture.h"
#import "SPSettings.h"

// ════════════════════════════════════════════════════════════════════════════
// 注入层。两条铁律：
//  1) 不硬链接 libsubstrate —— 用 dlsym 拿 MSHookMessageEx。
//     硬链接 @loader_path/.jbroot/usr/lib/libsubstrate.dylib 在非 roothide 布局下
//     dlopen 直接失败，整个 dylib 不加载（v0.1.x 就是这么死的）。
//  2) constructor 第一件事就写日志 + 弹可见浮条。
//     看得见浮条 = 注入成功；看不见 = 跟手势逻辑无关，别再瞎调参数。
// ════════════════════════════════════════════════════════════════════════════

typedef void (*SPHookMsgExFn)(Class, SEL, IMP, IMP *);
static SPHookMsgExFn gHookMsgEx = NULL;

static IMP gOrigTouchesBegan = NULL;
static IMP gOrigTouchesEnded = NULL;
static IMP gOrigTouchesCancelled = NULL;

static void SPHookedTouchesBegan(id self, SEL _cmd, NSSet *touches, UIEvent *event) {
    if (gOrigTouchesBegan)
        ((void (*)(id, SEL, NSSet *, UIEvent *))gOrigTouchesBegan)(self, _cmd, touches, event);
    if (![SPSettings enabled]) return;
    CGPoint p = CGPointZero;
    SEL loc = NSSelectorFromString(@"locationInView:");
    if ([self respondsToSelector:loc])
        p = ((CGPoint (*)(id, SEL, id))objc_msgSend)(self, loc, nil);
    [[SPGesture shared] handleHomePanBegan:p];
}

static void SPHookedTouchesEnded(id self, SEL _cmd, NSSet *touches, UIEvent *event) {
    if ([SPSettings enabled]) {
        CGPoint t = CGPointZero, v = CGPointZero;
        SEL tr = NSSelectorFromString(@"translationInView:");
        SEL ve = NSSelectorFromString(@"velocityInView:");
        if ([self respondsToSelector:tr])
            t = ((CGPoint (*)(id, SEL, id))objc_msgSend)(self, tr, nil);
        if ([self respondsToSelector:ve])
            v = ((CGPoint (*)(id, SEL, id))objc_msgSend)(self, ve, nil);
        [[SPGesture shared] consumeHomePan:nil translation:t velocity:v];
    }
    if (gOrigTouchesEnded)
        ((void (*)(id, SEL, NSSet *, UIEvent *))gOrigTouchesEnded)(self, _cmd, touches, event);
}

static void SPHookedTouchesCancelled(id self, SEL _cmd, NSSet *touches, UIEvent *event) {
    if (gOrigTouchesCancelled)
        ((void (*)(id, SEL, NSSet *, UIEvent *))gOrigTouchesCancelled)(self, _cmd, touches, event);
}

void SPWriteEnvironmentProbe(void);

static BOOL SPInstallGestureHooks(void) {
    Class cls = NSClassFromString(@"SBHomeGesturePanGestureRecognizer");
    if (!cls) { SPLog(@"hook: class missing"); return NO; }
    if (!gHookMsgEx) { SPLog(@"hook: MSHookMessageEx unavailable"); return NO; }
    gHookMsgEx(cls, NSSelectorFromString(@"touchesBegan:withEvent:"), (IMP)SPHookedTouchesBegan, &gOrigTouchesBegan);
    gHookMsgEx(cls, NSSelectorFromString(@"touchesEnded:withEvent:"), (IMP)SPHookedTouchesEnded, &gOrigTouchesEnded);
    gHookMsgEx(cls, NSSelectorFromString(@"touchesCancelled:withEvent:"), (IMP)SPHookedTouchesCancelled, &gOrigTouchesCancelled);
    BOOL ok = (gOrigTouchesEnded != NULL);
    SPLog(@"hook: installed=%d began=%d ended=%d", ok, gOrigTouchesBegan != NULL, gOrigTouchesEnded != NULL);
    return ok;
}

__attribute__((constructor)) static void SPSplitPaneInit(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        SPLog(@"=== SplitPane 0.2.1 loaded (bundle=%@ pid=%d) log=%@ ===",
              bid ?: @"?", getpid(), SPLogPath());
        if (![bid isEqualToString:@"com.apple.springboard"]) {
            SPLog(@"not springboard, idle");
            return;
        }
        gHookMsgEx = (SPHookMsgExFn)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
        SPLog(@"dlsym MSHookMessageEx -> %p", gHookMsgEx);

        dispatch_async(dispatch_get_main_queue(), ^{
            [SPSettings startObserving];
            SPWriteEnvironmentProbe();
            BOOL hooked = SPInstallGestureHooks();
            [SPGesture shared].hooksAvailable = hooked;
            NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
            [nc addObserverForName:UISceneDidActivateNotification object:nil queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *n) {
                if ([n.object isKindOfClass:[UIWindowScene class]])
                    [[SPGesture shared] installInWindowScene:(UIWindowScene *)n.object];
            }];
            [[SPGesture shared] installInWindowScene:nil];
            SPShowLoadBanner(hooked
                ? [NSString stringWithFormat:@"SplitPane 0.2.1 已加载 · %@", [SPLogPath() lastPathComponent]]
                : @"SplitPane 0.2.1 已加载 · 钩子失败，用状态栏双击");
        });
    }
}