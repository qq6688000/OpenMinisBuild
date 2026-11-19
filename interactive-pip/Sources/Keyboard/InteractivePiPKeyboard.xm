// InteractivePiP keyboard module — injected into com.apple.UIKit (process "kbd").
// The system keyboard lives in THIS process, not in SpringBoard. SpringBoard
// cannot hand the keyboard to a hosted window, so this module measures the
// keyboard here and broadcasts visible/height over a Darwin notification.
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import <objc/message.h>

static NSString *const kIPKBVisible = @"com.seagull.interactivepip.kb.visible";
static NSString *const kIPKBHeight  = @"com.seagull.interactivepip.kb.height";
static int sVisToken = 0, sHeightToken = 0;

static void IPPublish(void) {
    id kb = nil;
    Class cls = NSClassFromString(@"_UIRemoteKeyboards");
    SEL shared = NSSelectorFromString(@"sharedRemoteKeyboards");
    if (cls && [cls respondsToSelector:shared])
        kb = ((id (*)(id, SEL))objc_msgSend)(cls, shared);

    BOOL visible = NO;
    double height = 0;

    if (kb) {
        SEL visSel = NSSelectorFromString(@"keyboardVisible");
        if ([kb respondsToSelector:visSel])
            visible = ((BOOL (*)(id, SEL))objc_msgSend)(kb, visSel);

        SEL winSel = NSSelectorFromString(@"keyboardWindow");
        if (visible && [kb respondsToSelector:winSel]) {
            UIWindow *w = ((id (*)(id, SEL))objc_msgSend)(kb, winSel);
            if (w && !w.hidden && w.frame.size.height > 1) {
                CGRect f = w.frame;
                CGRect screen = w.screen ? w.screen.bounds : UIScreen.mainScreen.bounds;
                // On rotation the keyboard frame is pre-transformed.
                double h = (f.size.height > screen.size.height * 0.5) ? f.size.width : f.size.height;
                height = MAX(0.0, h - w.safeAreaInsets.bottom);
            } else {
                visible = NO;
            }
        }
    }

    notify_set_state(sVisToken, visible ? 1 : 0);
    notify_set_state(sHeightToken, (uint64_t)llround(height * 10.0));
    notify_post(kIPKBVisible.UTF8String);
    notify_post(kIPKBHeight.UTF8String);
}

@interface IPKeyboardTicker : NSObject
@property (nonatomic, strong) NSTimer *timer;
@end

@implementation IPKeyboardTicker
+ (instancetype)shared {
    static IPKeyboardTicker *o;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ o = [IPKeyboardTicker new]; });
    return o;
}
- (void)tick { IPPublish(); }
- (void)start {
    if (self.timer) return;
    self.timer = [NSTimer timerWithTimeInterval:0.2 target:self
                                       selector:@selector(tick) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    IPPublish();
    NSLog(@"[InteractivePiP/kbd] keyboard module active in %@",
          [NSProcessInfo processInfo].processName);
}
@end

__attribute__((constructor)) static void IPKeyboardInit(void) {
    @autoreleasepool {
        notify_register_check(kIPKBVisible.UTF8String, &sVisToken);
        notify_register_check(kIPKBHeight.UTF8String, &sHeightToken);
        // kbd may not have a run loop yet; retry until it does.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[IPKeyboardTicker shared] start];
        });
    }
}
