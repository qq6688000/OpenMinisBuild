#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SPCompat.h"
#import "SPLog.h"
#import "SPGesture.h"
#import "SPHost.h"
#import "SPPaneController.h"
#import "SPSettings.h"
#import "SPAppPicker.h"

// ============================================================================
// PV 式编排：App 内上划到灵动岛 → 该 App 被挂起 → 用户手动开另一个 App → 自动分屏
//
// 用户要的完整流程：
//   1) 任意全屏 App 内，从底部上划
//   2) 划到灵动岛高度时松手 → 当前 App 挂起（不退出、不黑屏）
//   3) 回到桌面，用户自己点开任意一个 App
//   4) 那个新 App 进下半屏，挂起的进上半屏 → 分屏成立
//
// 实现要点：
//   · 挂起 = 记住 bundleID + 实时快照，然后把 App 交回系统（它会自己回后台）
//   · 监听前台 App 变化：一旦出现「挂起 App 之外的新前台」，立刻组建分屏
//   · 全程不依赖 homePress（这台机器上不可靠）
// ============================================================================

@interface SPParkedSession : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, strong) UIImage *snapshot;
@property (nonatomic, assign) CFTimeInterval at;
@end
@implementation SPParkedSession
@end

static SPParkedSession *gParked = nil;
static BOOL gArmed = NO;          // 正在等待「用户手动打开新 App」
static id gObserver = nil;
static id gSettingsObserver = nil;
static NSUInteger gGeneration = 0;
static BOOL gLaunching = NO;

@interface SPParked : NSObject
+ (void)cancelPendingSession;
+ (void)pollSession:(SPParkedSession *)session generation:(NSUInteger)generation count:(NSInteger)n;
@end

@implementation SPParked

+ (void)cancelPendingSession {
    ++gGeneration;
    gArmed = NO;
    gLaunching = NO;
    gParked = nil;
}

+ (void)pollSession:(SPParkedSession *)session generation:(NSUInteger)generation count:(NSInteger)n {
    if (generation != gGeneration || gParked != session || !gArmed) return;
    if (![SPSettings enabled] || SPPaneController.shared.active || [SPAppPicker isPresenting] ||
        n > 40 || CACurrentMediaTime() - session.at >= 15.0) {
        [self cancelPendingSession];
        return;
    }
    @try {
        NSString *front = [[SPGesture shared] frontmostBundleID];
        if (front.length &&
            ![front isEqualToString:session.bundleID] &&
            ![front isEqualToString:@"com.apple.springboard"] &&
            ![front containsString:@"Spotlight"]) {
            SPLog(@"parked: poll 发现新前台 %@", front);
            [self triggerSplitWith:front];
        }
    } @catch (__unused NSException *e) {}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self pollSession:session generation:generation count:n + 1];
    });
}

+ (void)install {
    if (gObserver) return;
    // 监听前台 App 变化。SBApplicationDidBecomeActiveNotification 带 userInfo 里的 SBApplication 对象。
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    gObserver = [nc addObserverForName:@"SBApplicationDidBecomeActiveNotification"
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(NSNotification *n) {
        @try { [self handleBecameActive:n]; } @catch (NSException *e) { SPLog(@"parked obs ex %@", e.reason); }
    }];
    gSettingsObserver = [nc addObserverForName:SPNotifyChanged object:nil
                                       queue:[NSOperationQueue mainQueue]
                                  usingBlock:^(NSNotification *n) {
        if (![SPSettings enabled]) [self cancelPendingSession];
    }];
    SPLog(@"parked: observer installed");
}

+ (NSString *)bundleIDFromNotification:(NSNotification *)n {
    id app = n.userInfo[@"SBApplication"];
    if (!app) app = n.object;
    if (!app) return nil;
    for (NSString *k in @[@"bundleIdentifier", @"_bundleIdentifier"]) {
        SEL s = NSSelectorFromString(k);
        if (![app respondsToSelector:s]) continue;
        @try {
            id v = ((id (*)(id, SEL))objc_msgSend)(app, s);
            if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) return v;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

+ (void)handleBecameActive:(NSNotification *)n {
    if (!gArmed || !gParked) return;
    [self triggerSplitWith:[self bundleIDFromNotification:n]];
}

+ (void)triggerSplitWith:(NSString *)bid {
    if (!gArmed || !gParked || !bid.length || [bid isEqualToString:gParked.bundleID] ||
        [bid isEqualToString:@"com.apple.springboard"] || [bid containsString:@"Spotlight"]) return;
    if (![SPSettings enabled] || SPPaneController.shared.active || [SPAppPicker isPresenting]) {
        [self cancelPendingSession];
        return;
    }
    UIWindowScene *ws = nil;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]] ||
            sc.activationState != UISceneActivationStateForegroundActive ||
            [NSStringFromClass(sc.class) containsString:@"Aperture"]) continue;
        ws = (UIWindowScene *)sc; break;
    }
    if (!ws) { SPLog(@"parked: 找不到 windowScene，继续等待"); return; }

    SPParkedSession *session = gParked;
    NSUInteger generation = gGeneration;
    gArmed = NO;
    gLaunching = YES;
    // 新 App 启动后仍须是同一会话、同一前台；不能在用户取消或改开第三个 App 后抢回来。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != gGeneration || gParked != session || !gLaunching) return;
        NSString *front = [[SPGesture shared] frontmostBundleID];
        if (![SPSettings enabled] || SPPaneController.shared.active || [SPAppPicker isPresenting] ||
            ws.activationState != UISceneActivationStateForegroundActive ||
            ![[UIApplication sharedApplication].connectedScenes containsObject:ws] ||
            ![front isEqualToString:bid]) {
            [self cancelPendingSession];
            return;
        }
        SPLog(@"parked: start split top=%@ bottom=%@", session.bundleID, bid);
        BOOL started = [SPPaneController.shared startWithTop:session.bundleID bottom:bid
                                                windowScene:ws topSnapshot:session.snapshot];
        SPLog(@"parked: start result=%d", (int)started);
        [self cancelPendingSession];
    });
}

// 上划到灵动岛高度松手 → 调用这里
+ (void)parkFrontmostApp {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self parkFrontmostApp]; });
        return;
    }
    if (![SPSettings enabled] || SPPaneController.shared.active || [SPAppPicker isPresenting] || gArmed || gLaunching) {
        SPLog(@"parked: 当前不可挂起，忽略");
        return;
    }
    SPParkedSession *ps = [SPParkedSession new];
    ps.bundleID = [[SPGesture shared] frontmostBundleID];
    ps.at = CACurrentMediaTime();
    if (!ps.bundleID.length || [ps.bundleID isEqualToString:@"com.apple.springboard"]) {
        SPLog(@"parked: 没有前台 App，忽略");
        return;
    }
    ps.snapshot = [[SPGesture shared] snapshotScreen];
    gParked = ps;
    gArmed = YES;
    NSUInteger generation = ++gGeneration;
    SPLog(@"parked: %@ 已挂起，等待用户打开第二个 App", ps.bundleID);

    // 让 App 真正退到后台（桌面随之出现）。
    // sendHomePress 在这台机器上调用返回成功但不转场（日志实证），
    // 唯一可靠的是直接把它的 FBScene 推成 backgrounded。
    NSString *target = ps.bundleID;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != gGeneration || gParked != ps || !gArmed || ![SPSettings enabled] ||
            SPPaneController.shared.active || [SPAppPicker isPresenting]) return;
        BOOL bg = NO;
        @try { bg = [SPHost pushSceneToBackground:target]; }
        @catch (__unused NSException *e) {}
        SPLog(@"parked: pushSceneToBackground(%@)=%d", target, (int)bg);
        // 再补一次 homePress 冲一下转场（失败也无所谓）
        @try { [[SPGesture shared] sendHomePress]; } @catch (__unused NSException *e) {}
    });

    // 轮询兜底：通知有时收不到（SpringBoard 里 post 的时机不确定），
    // 每 0.4s 查一次前台 App，发现新的就组建分屏。
    [self pollSession:ps generation:generation count:0];

    // 15 秒没开新 App 就自动放弃
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation == gGeneration && gParked == ps) {
            [self cancelPendingSession];
            SPLog(@"parked: 超时放弃");
        }
    });
}

+ (BOOL)isArmed { return gArmed || gLaunching; }
+ (NSString *)parkedBundleID { return gParked.bundleID; }

@end
