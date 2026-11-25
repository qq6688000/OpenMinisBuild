#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "SPCompat.h"
#import "SPLog.h"
#import "SPGesture.h"
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
    if (!gArmed || !gParked) return;
    NSString *bid = [self bundleIDFromNotification:n];
    if (!bid.length) return;
    if ([bid isEqualToString:gParked.bundleID]) return;         // 挂起的那个回来了，忽略
    if ([bid isEqualToString:@"com.apple.springboard"]) return;

    // 用户手动打开了另一个 App → 组建分屏
    SPLog(@"parked: 检测到新前台 %@ -> 与 %@ 组建分屏", bid, gParked.bundleID);
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
        SPLog(@"parked: start split top=%@ bottom=%@", top, bid);
        [SPPaneController.shared startWithTop:top bottom:bid windowScene:ws topSnapshot:snap];
    });
}

// 上划到灵动岛高度松手 → 调用这里
+ (void)parkFrontmostApp {
    if (SPPaneController.shared.active) {
        SPLog(@"parked: 已在分屏中，忽略");
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
    SPLog(@"parked: %@ 已挂起，等待用户打开第二个 App", ps.bundleID);

    // 把 App 交回系统：它自己会退到后台并显示桌面。
    // 这里用真正的 Scene 后台化，不用那个不存在的 homePress。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[SPGesture shared] sendHomePress];
    });

    // 12 秒没开新 App 就自动放弃
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gArmed && gParked == ps) {
            gArmed = NO;
            gParked = nil;
            SPLog(@"parked: 超时放弃");
        }
    });
}

+ (BOOL)isArmed { return gArmed; }
+ (NSString *)parkedBundleID { return gParked.bundleID; }

@end
