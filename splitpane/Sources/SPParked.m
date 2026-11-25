#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SPCompat.h"
#import "SPLog.h"
#import "SPGesture.h"
#import "SPSettings.h"
#import "SPHost.h"
#import "SPPaneController.h"

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

@interface SPParked : NSObject
@end

@implementation SPParked

static BOOL gPolling = NO;
static NSUInteger gGeneration = 0;

+ (void)cancel {
    ++gGeneration;
    gArmed = NO;
    gParked = nil;
    gPolling = NO;
}

+ (void)startPolling {
    if (gPolling) return;
    gPolling = YES;
    [self pollOnce:@(gGeneration) count:0];
}

+ (void)pollOnce:(NSNumber *)ticket count:(NSInteger)n {
    if (ticket.unsignedIntegerValue != gGeneration) return;
    if (![SPSettings enabled]) { [self cancel]; return; }
    if (!gArmed || !gParked || n > 40) { gPolling = NO; return; }
    @try {
        NSString *front = [[SPGesture shared] frontmostBundleID];
        if (front.length &&
            ![front isEqualToString:gParked.bundleID] &&
            ![front isEqualToString:@"com.apple.springboard"] &&
            ![front containsString:@"Spotlight"]) {
            SPLog(@"parked: poll 发现新前台 %@", front);
            [self triggerSplitWith:front];
            gPolling = NO;
            return;
        }
    } @catch (__unused NSException *e) {}
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [self pollOnce:ticket count:n + 1]; });
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
    if (![SPSettings enabled]) { [self cancel]; return; }
    if (!gArmed || !gParked) return;
    NSString *bid = [self bundleIDFromNotification:n];
    if (!bid.length) return;
    if ([bid isEqualToString:gParked.bundleID]) return;         // 挂起的那个回来了，忽略
    if ([bid isEqualToString:@"com.apple.springboard"]) return;

    SPLog(@"parked: 检测到新前台 %@ -> 与 %@ 组建分屏", bid, gParked.bundleID);
    [self triggerSplitWith:bid];
}

+ (void)triggerSplitWith:(NSString *)bid {
    if (![SPSettings enabled]) { [self cancel]; return; }
    if (!gArmed || !gParked) return;
    const NSUInteger ticket = gGeneration;
    gArmed = NO;

    NSString *top = gParked.bundleID;
    UIImage *snap = gParked.snapshot;
    gParked = nil;

    UIWindowScene *ws = nil;
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        NSString *cn = NSStringFromClass([sc class]);
        if ([cn containsString:@"Aperture"]) continue;
        ws = (UIWindowScene *)sc; break;
    }
    if (!ws) { SPLog(@"parked: 找不到 windowScene"); return; }

    // 稍等一下，让用户刚打开的 App 完成启动
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (ticket != gGeneration || ![SPSettings enabled] || SPPaneController.shared.active) return;
        SPLog(@"parked: start split top=%@ bottom=%@", top, bid);
        [SPPaneController.shared startWithTop:top bottom:bid windowScene:ws topSnapshot:snap];
    });
}

// 上划到灵动岛高度松手 → 调用这里
+ (void)parkFrontmostApp {
    if (![SPSettings enabled]) { [self cancel]; return; }
    if (SPPaneController.shared.active) {
        SPLog(@"parked: 已在分屏中，忽略");
        return;
    }
    [self cancel];
    const NSUInteger ticket = gGeneration;
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
    SPLog(@"parked: %@ 已挂起，等待用户打开第二个 App", ps.bundleID);

    // 让 App 真正退到后台（桌面随之出现）。
    // sendHomePress 在这台机器上调用返回成功但不转场（日志实证），
    // 唯一可靠的是直接把它的 FBScene 推成 backgrounded。
    NSString *target = ps.bundleID;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (ticket != gGeneration || gParked != ps || ![SPSettings enabled]) return;
        BOOL bg = NO;
        @try { bg = [SPHost pushSceneToBackground:target]; }
        @catch (__unused NSException *e) {}
        SPLog(@"parked: pushSceneToBackground(%@)=%d", target, (int)bg);
        // 再补一次 homePress 冲一下转场（失败也无所谓）
        @try { [[SPGesture shared] sendHomePress]; } @catch (__unused NSException *e) {}
    });

    // 轮询兜底：通知有时收不到（SpringBoard 里 post 的时机不确定），
    // 每 0.4s 查一次前台 App，发现新的就组建分屏。
    [self startPolling];

    // 15 秒没开新 App 就自动放弃
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (ticket == gGeneration && gArmed && gParked == ps) {
            [self cancel];
            SPLog(@"parked: 超时放弃");
        }
    });
}

+ (BOOL)isArmed { return gArmed; }
+ (NSString *)parkedBundleID { return gParked.bundleID; }

@end
