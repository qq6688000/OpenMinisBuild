#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "SPCompat.h"
#import "SPGesture.h"
#import "SPSettings.h"
#import "SPPaneController.h"

// 入口注入层。
// iOS 16 的底部上滑真身是 SBHomeGesturePanGestureRecognizer（Duo split_16 实证），
// 不是 SBFluidSwitcherScreenEdgePanGestureRecognizer。这里只接管「往上拎到位」的一次，
// 其余一律交回系统；并且绝不跳过原实现（跳过会把过渡动画冻在中间帧）。

static void (*origTouchesBegan)(id, SEL, NSSet *, UIEvent *);
static void (*origTouchesEnded)(id, SEL, NSSet *, UIEvent *);
static void (*origTouchesCancelled)(id, SEL, NSSet *, UIEvent *);

static void SPHookedTouchesBegan(id self, SEL _cmd, NSSet *touches, UIEvent *event) {
    if (origTouchesBegan) origTouchesBegan(self, _cmd, touches, event);
    if (![SPSettings enabled]) return;
    CGPoint p = CGPointZero;
    SEL loc = NSSelectorFromString(@"locationInView:");
    if ([self respondsToSelector:loc])
        p = ((CGPoint (*)(id, SEL, id))objc_msgSend)(self, loc, nil);
    [[SPGesture shared] handleHomePanBegan:p];
}

static void SPHookedTouchesEnded(id self, SEL _cmd, NSSet *touches, UIEvent *event) {
    BOOL took = NO;
    if ([SPSettings enabled]) {
        CGPoint t = CGPointZero, v = CGPointZero;
        SEL tr = NSSelectorFromString(@"translationInView:");
        SEL ve = NSSelectorFromString(@"velocityInView:");
        if ([self respondsToSelector:tr])
            t = ((CGPoint (*)(id, SEL, id))objc_msgSend)(self, tr, nil);
        if ([self respondsToSelector:ve])
            v = ((CGPoint (*)(id, SEL, id))objc_msgSend)(self, ve, nil);
        took = [[SPGesture shared] consumeHomePan:nil translation:t velocity:v];
    }
    if (origTouchesEnded) origTouchesEnded(self, _cmd, touches, event);
    (void)took;
}

static void SPHookedTouchesCancelled(id self, SEL _cmd, NSSet *touches, UIEvent *event) {
    if (origTouchesCancelled) origTouchesCancelled(self, _cmd, touches, event);
}

static void SPInstallGestureHooks(void) {
    Class cls = NSClassFromString(@"SBHomeGesturePanGestureRecognizer");
    if (!cls) {
        NSLog(@"[SplitPane] SBHomeGesturePanGestureRecognizer not found");
        return;
    }
    SEL b = NSSelectorFromString(@"touchesBegan:withEvent:");
    SEL e = NSSelectorFromString(@"touchesEnded:withEvent:");
    SEL c = NSSelectorFromString(@"touchesCancelled:withEvent:");
    MSHookMessageEx(cls, b, (IMP)SPHookedTouchesBegan, (IMP *)&origTouchesBegan);
    MSHookMessageEx(cls, e, (IMP)SPHookedTouchesEnded, (IMP *)&origTouchesEnded);
    MSHookMessageEx(cls, c, (IMP)SPHookedTouchesCancelled, (IMP *)&origTouchesCancelled);
    NSLog(@"[SplitPane] home gesture hooked");
}

__attribute__((constructor)) static void SPSplitPaneInit(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (![bid isEqualToString:@"com.apple.springboard"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [SPSettings startObserving];
            SPInstallGestureHooks();
            NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
            [nc addObserverForName:UISceneDidActivateNotification object:nil queue:[NSOperationQueue mainQueue]
                        usingBlock:^(NSNotification *n) {
                if ([n.object isKindOfClass:[UIWindowScene class]])
                    [[SPGesture shared] installInWindowScene:(UIWindowScene *)n.object];
            }];
            [[SPGesture shared] installInWindowScene:nil];
        });
    }
}
