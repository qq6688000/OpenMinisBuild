#import "SPHost.h"
#import "SPSettings.h"
#import "SPLog.h"
#import <objc/runtime.h>
#import <math.h>

// ════════════════════════════════════════════════════════════════════════════
// 一个 App 的画面。真实链路（抄 Duo 在 16.4.1 上跑通的实证，不是猜）：
//
//   1) FBSceneManager enumerateScenesWithBlock → 按 clientProcess.bundleIdentifier
//      找到真 FBScene（SBApplication.mainScene 不是 FBScene）
//   2) SBMainWorkspace.mainWindowScene.sceneManager existingSceneHandleForScene:
//      → 拿到真正拥有工厂的句柄
//   3) 句柄上唯一存在的工厂：
//      newSceneViewWithReferenceSize:contentOrientation:containerOrientation:hostRequester:
//      （本机没有 newSceneViewWithReferenceSize: 单参版，日志实证 0.2.2 三个都 n）
//   4) 必须推 FBScene.updateSettings:，否则画面仍按全屏渲染，host 是空的
//
// 日志实证（0.2.2）：newSceneViewWithReferenceSize=n / createSceneView=n /
// initWithScene=n，allScenes=0 —— 全是我猜错了名字。
// ════════════════════════════════════════════════════════════════════════════

@implementation SPHostRequester
- (instancetype)init {
    if ((self = [super init]))
        _presentationIdentifier = [@"com.seagull.splitpane.host."
                                   stringByAppendingString:NSUUID.UUID.UUIDString];
    return self;
}
- (NSString *)sceneViewPresentationIdentifier:(id)view { (void)view; return self.presentationIdentifier; }
- (long long)sceneViewPresentationPriority:(id)view { (void)view; return 1; }
@end

@interface SPHost ()
@property (nonatomic, copy, readwrite) NSString *bundleID;
@property (nonatomic, weak, readwrite) UIView *containerView;
@property (nonatomic, strong) UIView *hostView;
@property (nonatomic, strong) UIImageView *snapshotView;
@property (nonatomic, strong) id scene;
@property (nonatomic, assign) CGSize referenceSize;
@end

void SPHostRegisterHostedScene(id scene, id owner);
void SPHostUnregisterHostedScene(id scene, id owner);
void SPRepairRecordSceneSettings(id scene, NSDictionary *settings);
NSDictionary *SPRepairOriginalSettingsForScene(id scene);
void SPRepairForgetScene(id scene);
BOOL SPRepairRestoreSceneGeometry(id scene, NSDictionary *settings, NSString **diag);

@interface SPHost ()
- (void)detach;
- (BOOL)tryAttachToContainer:(UIView *)container inWindowScene:(UIWindowScene *)windowScene;
- (void)attemptAttachToContainer:(UIView *)container inWindowScene:(UIWindowScene *)windowScene
                     attempts:(NSInteger)attempts interval:(NSTimeInterval)interval generation:(NSUInteger)generation;
- (void)releaseHostedPresentation;
- (void)layoutSnapshot;
- (void)waitForContentReady:(NSInteger)tries generation:(NSUInteger)generation;
@property (nonatomic, strong) id handle;
@property (nonatomic, strong) SPHostRequester *requester;
@property (nonatomic, strong) id controller;
@property (nonatomic, strong) NSObject *registrationToken;
@property (nonatomic, strong) UIImage *pendingSnapshot;
@property (nonatomic, assign, readwrite) BOOL live;
@property (nonatomic, assign) BOOL attached;
@property (nonatomic, assign) BOOL contentPolling;
@property (nonatomic, assign) BOOL callbacksEnabled;
@property (nonatomic, assign) NSUInteger attachmentGeneration;
@property (nonatomic, assign) CGSize lastSize;
@property (nonatomic, strong) NSDictionary *originalSettings;   // 只保存本宿主会修改的几何值
@property (nonatomic, assign) BOOL touchedSettings;
@end

static BOOL SPHostOnMain(NSString *operation) {
    if ([NSThread isMainThread]) return YES;
    SPLog(@"host %@ rejected off-main", operation);
    return NO;
}

// 所有清理路径共用；不要同时调用 invalidate 和 detachScene，避免二次释放呈现权。
static void SPReleaseSceneView(UIView *view, id controller) {
    UIViewController *vc = [controller isKindOfClass:[UIViewController class]] ? controller : nil;
    if (vc.parentViewController) [vc willMoveToParentViewController:nil];
    for (NSString *name in @[@"invalidate", @"detachScene"]) {
        if (!SPABI(view, name, "v", 0)) continue;
        @try { ((void (*)(id, SEL))objc_msgSend)(view, NSSelectorFromString(name)); break; }
        @catch (NSException *e) { SPLog(@"host release %@ ex %@", name, e.reason); }
    }
    [view removeFromSuperview];
    if (vc.parentViewController) [vc removeFromParentViewController];
}

static BOOL SPSceneHasContent(id scene) {
    if (!SPABI(scene, @"isValid", @encode(BOOL), 0) || !SPBool0(scene, @"isValid")) return NO;
    if (!SPABI(scene, @"contentState", @encode(NSInteger), 0)) return NO;
    // 0/1 不能证明已有渲染内容；不能再靠 subviews/layers 个数把空 sceneView 判为 live。
    return SPInt0(scene, @"contentState") == 2;
}

@implementation SPHost

#pragma mark - 场景入口

+ (id)mainDisplaySceneManager {
    Class coord = NSClassFromString(@"SBSceneManagerCoordinator");
    if (coord) {
        id m = SPMsg0(coord, @"mainDisplaySceneManager");
        if (!m) m = SPMsg0(coord, @"secureMainDisplaySceneManager");
        if (m) return m;
    }
    return nil;
}

+ (id)applicationProxyForBundleID:(NSString *)bundleID {
    if (!bundleID.length) return nil;
    Class ac = NSClassFromString(@"SBApplicationController");
    if (!ac) return nil;
    id ctrl = SPMsg0(ac, @"sharedInstance");
    if (!ctrl) return nil;
    id app = SPMsg1(ctrl, @"applicationWithBundleIdentifier:", bundleID);
    if (!app) app = SPMsg1(ctrl, @"applicationWithDisplayIdentifier:", bundleID);
    return app;
}

static BOOL SPObjectMatchesBundleID(id obj, NSString *bundleID) {
    if (!obj) return NO;
    @try {
        id proc = SPMsg0(obj, @"clientProcess");
        if (proc) {
            id ca = SPMsg0(proc, @"bundleIdentifier");
            if ([ca isKindOfClass:[NSString class]] && [(NSString *)ca isEqualToString:bundleID]) return YES;
        }
        id app = SPMsg0(obj, @"application");
        if (app) {
            id a = SPMsg0(app, @"bundleIdentifier");
            if ([a isKindOfClass:[NSString class]] && [(NSString *)a isEqualToString:bundleID]) return YES;
        }
        id ident = SPMsg0(obj, @"identifier");
        if ([ident isKindOfClass:[NSString class]] && [(NSString *)ident containsString:bundleID]) return YES;
    } @catch (__unused NSException *e) {}
    return NO;
}

// 真的 FBScene：靠 FBSceneManager 枚举 + clientProcess.bundleIdentifier 比对。
// allScenes / mainScene 都不是 FBScene，这是 Duo 0.7.91 的定案。
+ (id)fbSceneForBundleID:(NSString *)bundleID {
    if (!bundleID.length) return nil;
    Class mgrCls = NSClassFromString(@"FBSceneManager");
    id mgr = mgrCls ? SPMsg0(mgrCls, @"sharedInstance") : nil;
    if (!mgr) { SPLog(@"fbScene %@: no FBSceneManager", bundleID); return nil; }

    SEL enumSel = NSSelectorFromString(@"enumerateScenesWithBlock:");
    if ([mgr respondsToSelector:enumSel]) {
        // ⚠️ 这个 block 是单参数 ^(id scene)。写成 ^(id, BOOL*) 会参数不匹配抛异常，
        // 被 @catch 吞掉后看起来「一个 scene 都没有」—— 0.3.2 的 no-scene 就是这么来的。
        __block id match = nil;
        __block NSUInteger scanned = 0;
        void (^block)(id) = ^(id candidate) {
            @try {
                scanned++;
                id proc = SPMsg0(candidate, @"clientProcess");
                NSString *bundle = SPMsg0(proc, @"bundleIdentifier");
                if (![bundle isKindOfClass:[NSString class]]) {
                    id info = SPMsg0(proc, @"applicationInfo");
                    bundle = SPMsg0(info, @"bundleIdentifier");
                }
                BOOL same = [bundle isKindOfClass:[NSString class]] &&
                            [(NSString *)bundle isEqualToString:bundleID];
                if (!same) {
                    NSString *ident = SPMsg0(candidate, @"identifier");
                    if ([ident isKindOfClass:[NSString class]]) {
                        same = [(NSString *)ident isEqualToString:bundleID] ||
                               [(NSString *)ident hasPrefix:[@"sceneID:" stringByAppendingString:bundleID]];
                    }
                }
                if (same && !match) match = candidate;
            } @catch (__unused NSException *e) {}
        };
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(mgr, enumSel, block);
            SPLog(@"fbScene scan %@: scanned=%lu match=%@", bundleID, (unsigned long)scanned,
                  match ? NSStringFromClass([match class]) : @"nil");
        } @catch (NSException *e) {
            SPLog(@"fbScene enum ex %@", e.reason);
        }
        if (match) return match;
    } else {
        SPLog(@"fbScene: no enumerateScenesWithBlock: on %@", NSStringFromClass([mgr class]));
    }

    // 降级 A：从 App 自己的窗口树反查（刚激活的 App 常常在这里先有）
    @try {
        id app = [self applicationProxyForBundleID:bundleID];
        id scenes = SPMsg0(app, @"scenes");
        if ([scenes isKindOfClass:[NSSet class]]) scenes = [(NSSet *)scenes allObjects];
        if ([scenes isKindOfClass:[NSArray class]] && [(NSArray *)scenes count]) {
            SPLog(@"fbScene via app.scenes count=%lu", (unsigned long)[(NSArray *)scenes count]);
            return [(NSArray *)scenes firstObject];
        }
        id hs = SPMsg0(app, @"sceneHandles");
        if ([hs isKindOfClass:[NSArray class]] && [(NSArray *)hs count]) {
            for (id h in hs) {
                id sc = SPMsg0(h, @"scene");
                if (!sc) sc = SPMsg0(h, @"sceneIfExists");
                if (sc) { SPLog(@"fbScene via %@", NSStringFromClass([h class])); return sc; }
            }
        }
    } @catch (__unused NSException *e) {}

    // 降级 B：workspace 的 scene 字典
    @try {
        id workspace = SPMsg0(mgr, @"_workspace");
        for (NSString *key in @[@"_allScenesByID", @"_scenesByIdentifier", @"_scenesByID"]) {
            NSDictionary *map = SPMsg0(workspace, key);
            if (![map isKindOfClass:[NSDictionary class]]) continue;
            for (id ident in map) {
                if ([ident isKindOfClass:[NSString class]] && [(NSString *)ident containsString:bundleID]) {
                    SPLog(@"fbScene via %@", key);
                    return map[ident];
                }
            }
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

// 从 FBScene 反查真正拥有工厂的句柄（Duo 0.7.87 的 ZNS 口径）
+ (id)sceneHandleForScene:(id)scene {
    if (!scene) return nil;
    @try {
        Class wsCls = NSClassFromString(@"SBMainWorkspace");
        id ws = wsCls ? SPMsg0(wsCls, @"sharedInstance") : nil;
        id mainScene = SPMsg0(ws, @"mainWindowScene");
        id mgr = SPMsg0(mainScene, @"sceneManager");
        SEL look = NSSelectorFromString(@"existingSceneHandleForScene:");
        if (mgr && [mgr respondsToSelector:look]) {
            id h = ((id (*)(id, SEL, id))objc_msgSend)(mgr, look, scene);
            if (h) return h;
        }
    } @catch (NSException *e) { SPLog(@"handleForScene ex %@", e.reason); }

    id mgr = [self mainDisplaySceneManager];
    for (NSString *name in @[@"externalForegroundApplicationSceneHandles",
                             @"externalApplicationSceneHandles",
                             @"applicationSceneHandles", @"sceneHandles"]) {
        @try {
            id set = SPMsg0(mgr, name);
            if (!set) continue;
            NSArray *arr = nil;
            if ([set isKindOfClass:[NSArray class]]) arr = set;
            else if ([set respondsToSelector:@selector(allObjects)]) arr = [(NSSet *)set allObjects];
            for (id h in arr) {
                id s = SPMsg0(h, @"scene");
                if (s == scene) return h;
                if (SPObjectMatchesBundleID(h, self.class ? @"" : @"")) {}
            }
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

// 回桌面。SBUIController 在这台机器上没有那两个方法（日志 homePress=n），
// 所以多路探测：SBUIController / SBMainWorkspace / SBScreenFlash 之类的菜单键入口。
static NSMutableSet *gHomeTried = nil;

+ (NSString *)homePressDiag {
    return gHomeTried.count ? [[gHomeTried allObjects] componentsJoinedByString:@","] : @"none";
}


// 一次性把 SBUIController / SBMainWorkspace 上所有含 home/menu/返回 的方法打出来，
// 用于定名（不再猜）。
+ (void)dumpHomeAPIs {
    NSArray *classes = @[@"SBUIController", @"SBMainWorkspace", @"SBHomeScreenController",
                         @"SBMainSwitcherControllerCoordinator", @"SBWorkspace"];
    for (NSString *cn in classes) {
        Class c = NSClassFromString(cn);
        if (!c) { SPLog(@"homeAPI %@ = nil", cn); continue; }
        NSMutableArray *hits = [NSMutableArray array];
        unsigned int n = 0;
        Method *ms = class_copyMethodList(c, &n);
        for (unsigned int i = 0; i < n; i++) {
            const char *nm = sel_getName(method_getName(ms[i]));
            if (!nm) continue;
            NSString *s = @(nm);
            if ([s rangeOfString:@"ome" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [s rangeOfString:@"enu" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [s rangeOfString:@"xpose" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [s rangeOfString:@"witch" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                [hits addObject:s];
            }
        }
        free(ms);
        SPLog(@"homeAPI %@(%lu): %@", cn, (unsigned long)hits.count,
              [hits componentsJoinedByString:@" | "]);
    }
}


// 回桌面的第 3 条路：直接命令切换器回桌面。
// homePress 调用不抛异常（=1）但 SpringBoard 不一定真的转场（0.5.29 日志实证）。
// SBUIController 另有 handleHomeButtonDoublePressDown / 而 coordinator 上有
// dismissMainSwitcherNoninteractivelyAnimated: 和 activateMainSwitcherNoninteractivelyWithSource:animated:
+ (BOOL)forceHomeScreen {
    // 1) SBUIController 的双击 Down/Up 序列（等效连按两次 home）
    Class uic = NSClassFromString(@"SBUIController");
    id ui = uic ? SPMsg0(uic, @"sharedInstance") : nil;
    for (NSString *sn in @[@"handleHomeButtonDoublePressDown", @"handleHomeButtonDoublePressUp"]) {
        SEL sel = NSSelectorFromString(sn);
        if (ui && [ui respondsToSelector:sel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(ui, sel); SPLog(@"forceHome via %@", sn); return YES; }
            @catch (__unused NSException *e) {}
        }
    }
    // 2) coordinator：先让切换器显示桌面（activated 状态为 home）
    Class cc = NSClassFromString(@"SBMainSwitcherControllerCoordinator");
    id coord = cc ? SPMsg0(cc, @"sharedInstance") : nil;
    if (coord) {
        SEL d = NSSelectorFromString(@"dismissMainSwitcherNoninteractivelyAnimated:");
        if ([coord respondsToSelector:d]) {
            @try { ((void (*)(id, SEL, BOOL))objc_msgSend)(coord, d, NO);
                    SPLog(@"forceHome via dismissMainSwitcher"); return YES; }
            @catch (__unused NSException *e) {}
        }
        SEL a = NSSelectorFromString(@"activateMainSwitcherNoninteractivelyWithSource:animated:");
        if ([coord respondsToSelector:a]) {
            @try { ((void (*)(id, SEL, NSInteger, BOOL))objc_msgSend)(coord, a, 0, NO);
                    SPLog(@"forceHome via activateMainSwitcher"); return YES; }
            @catch (__unused NSException *e) {}
        }
    }
    SPLog(@"forceHome: none available");
    return NO;
}

+ (BOOL)homePressInWindowScene:(UIWindowScene *)ws {
    if (!ws) return NO;
    Class uic = NSClassFromString(@"SBUIController");
    id ui = uic ? SPMsg0(uic, @"sharedInstance") : nil;
    if (!ui) return NO;
    SEL s = NSSelectorFromString(@"handleHomeButtonSinglePressUpForWindowScene:");
    if (![ui respondsToSelector:s]) return NO;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(ui, s, ws);
        SPLog(@"homePress via own scene (%@)", NSStringFromClass([ws class]));
        return YES;
    } @catch (NSException *e) { SPLog(@"homePress(own) ex %@", e.reason); }
    return NO;
}

+ (BOOL)homePress {
    // 名字来自 0.5.23 的实测 dump（日志 "homeAPI SBUIController(18)"）：
    //   真正存在的是 handleHomeButtonSinglePressUpForWindowScene: 及带 sourceType 的变体，
    //   之前一直调的 handleHomeButtonSinglePressUp（无参）在这台机器上根本不存在。
    gHomeTried = [NSMutableSet set];

    Class uic = NSClassFromString(@"SBUIController");
    id ui = uic ? SPMsg0(uic, @"sharedInstance") : nil;
    if (!ui) { SPLog(@"homePress: SBUIController 无实例"); return NO; }

    // 取一个「正式显示」的 UIWindowScene。
    // ⚠️ 必须跳过 SBSystemApertureWindowScene（灵动岛）：
    // 它缺少 isExternalDisplayWindowScene 等方法，传给 SBUIController 会抛
    // unrecognized selector（0.5.25 日志实证：homePress ex1/ex2 都是这个异常）。
    UIWindowScene *ws = nil;
    NSMutableArray *dump = [NSMutableArray array];
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        NSString *cn = NSStringFromClass([sc class]);
        [dump addObject:[NSString stringWithFormat:@"%@(%ld)", cn, (long)sc.activationState]];
        if ([cn containsString:@"Aperture"]) continue;          // 灵动岛，跳过
        if ([cn containsString:@"TouchVisualizer"]) continue;
        if (sc.activationState == UISceneActivationStateForegroundActive) {
            if (!ws) ws = (UIWindowScene *)sc;
        }
    }
    if (!ws) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            NSString *cn = NSStringFromClass([sc class]);
            if ([cn containsString:@"Aperture"] || [cn containsString:@"TouchVisualizer"]) continue;
            if (!ws) ws = (UIWindowScene *)sc;
        }
    }
    SPLog(@"homePress scenes: %@ -> picked=%@", [dump componentsJoinedByString:@","],
          ws ? NSStringFromClass([ws class]) : @"nil");

    // 1) handleHomeButtonSinglePressUpForWindowScene:
    SEL s1 = NSSelectorFromString(@"handleHomeButtonSinglePressUpForWindowScene:");
    if (ws && [ui respondsToSelector:s1]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(ui, s1, ws);
            [gHomeTried addObject:@"SBUIController.handleHomeButtonSinglePressUpForWindowScene:"];
            SPLog(@"homePress via SPressUpForWindowScene");
            return YES;
        } @catch (NSException *e) { SPLog(@"homePress ex1 %@", e.reason); }
    }

    // 2) handleHomeButtonSinglePressUpForWindowScene:withSourceType:
    SEL s2 = NSSelectorFromString(@"handleHomeButtonSinglePressUpForWindowScene:withSourceType:");
    if (ws && [ui respondsToSelector:s2]) {
        @try {
            ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(ui, s2, ws, 0);
            [gHomeTried addObject:@"SBUIController.handleHomeButtonSinglePressUpForWindowScene:withSourceType:"];
            SPLog(@"homePress via SPressUpForWindowScene:withSourceType:");
            return YES;
        } @catch (NSException *e) { SPLog(@"homePress ex2 %@", e.reason); }
    }

    SPLog(@"homePress: none available (ws=%@)", ws ? @"Y" : @"n");
    return NO;
}

// ⚠️⚠️ 两件事都别做：
//   1) 别调 SBMainWorkspace 的 open*（实测同步阻塞 10 秒）
//   2) 也别在调用线程里直接调 LSApplicationWorkspace.openApplicationWithBundleID:
//      日志实证它同样阻塞 10007ms（0.4.2：`-> 0 (10007ms)`）
// 唯一安全的做法：扔到后台队列，立刻返回。UI 不等人。
+ (BOOL)openAppAsync:(NSString *)bundleID completion:(void (^)(BOOL))completion {
    if (!bundleID.length) return NO;
    if ([self fbSceneForBundleID:bundleID]) {
        SPLog(@"open %@ skipped (already has scene)", bundleID);
        if (completion) completion(YES);
        return YES;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        Class lsw = NSClassFromString(@"LSApplicationWorkspace");
        id workspace = lsw ? SPMsg0(lsw, @"defaultWorkspace") : nil;
        BOOL ok = NO;
        for (NSString *sn in @[@"openApplicationWithBundleID:", @"openApplicationWithBundleIdentifier:"]) {
            SEL sel = NSSelectorFromString(sn);
            if (![workspace respondsToSelector:sel]) continue;
            @try {
                CFTimeInterval t0 = CFAbsoluteTimeGetCurrent();
                ok = ((BOOL (*)(id, SEL, id))objc_msgSend)(workspace, sel, bundleID);
                SPLog(@"open %@ async via LS.%@ -> %d (%.0fms off-main)", bundleID, sn, (int)ok,
                      (CFAbsoluteTimeGetCurrent() - t0) * 1000);
                break;
            } @catch (NSException *e) { SPLog(@"LS open ex %@", e.reason); }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(ok); });
    });
    return YES;
}

+ (BOOL)openApp:(NSString *)bundleID suspended:(BOOL)suspended completion:(void (^)(BOOL))completion {
    return [self openAppAsync:bundleID completion:completion];
}

+ (void)reactivateApp:(NSString *)bundleID {
    if (!bundleID.length) return;
    // activateApplication: 只切前台身份，不启动进程，不会卡
    Class wsCls = NSClassFromString(@"SBWorkspace");
    id ws = wsCls ? SPMsg0(wsCls, @"mainWorkspace") : nil;
    if (!ws) wsCls = NSClassFromString(@"SBMainWorkspace"), ws = wsCls ? SPMsg0(wsCls, @"sharedInstance") : nil;
    id app = [self applicationProxyForBundleID:bundleID];
    SEL sel = NSSelectorFromString(@"activateApplication:withResult:");
    if (!ws || !app || ![ws respondsToSelector:sel]) return;
    @try {
        ((void (*)(id, SEL, id, id))objc_msgSend)(ws, sel, app, ^(BOOL ok) {
            SPLog(@"reactivate %@ -> %d", bundleID, (int)ok);
        });
    } @catch (NSException *e) { SPLog(@"reactivate ex %@", e.reason); }
}

// 把 App 退到后台：让它自己的 scene「收起」，SpringBoard 自然回桌面。
// 不杀进程 —— SIGKILL 会让 SpringBoard 认为 App 崩溃，可能触发重启。

// 真正把 App 退到后台（回桌面）。
// 这台机器 SBUIController / SBMainWorkspace 的 home 入口全部不可用（日志 homePress=n），
// 唯一可靠的做法是直接把它的 FBScene 推成 backgrounded=YES / foreground=NO，
// SpringBoard 看到前台 scene 全部退场，自然显示桌面。
+ (BOOL)pushSceneToBackground:(NSString *)bundleID {
    if (!bundleID.length) return NO;
    id scene = [self fbSceneForBundleID:bundleID];
    if (!scene) { SPLog(@"bg: %@ no scene", bundleID); return NO; }
    @try {
        id settings = SPGet(scene, @"settings");
        if (!settings) return NO;
        id desired = SPMsg0(settings, @"mutableCopy");
        if (!desired) return NO;

        BOOL did = NO;
        SEL bgSet = NSSelectorFromString(@"setBackgrounded:");
        if ([desired respondsToSelector:bgSet]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(desired, bgSet, YES);
            did = YES;
        }
        SEL fgSet = NSSelectorFromString(@"setForeground:");
        if ([desired respondsToSelector:fgSet]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(desired, fgSet, NO);
            did = YES;
        }
        SEL rsSet = NSSelectorFromString(@"setDeactivationReasons:");
        if ([desired respondsToSelector:rsSet]) {
            ((void (*)(id, SEL, unsigned long long))objc_msgSend)(desired, rsSet, 1ULL);
        }
        if (!did) { SPLog(@"bg: %@ no setter", bundleID); return NO; }

        id immutable = SPMsg0(desired, @"copy");
        if (!immutable) return NO;
        SEL upd = NSSelectorFromString(@"updateSettings:withTransitionContext:completion:");
        if ([scene respondsToSelector:upd]) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(scene, upd, immutable, nil, nil);
            SPLog(@"bg: %@ sent3", bundleID);
            return YES;
        }
        SEL upd2 = NSSelectorFromString(@"updateSettings:withTransitionContext:");
        if ([scene respondsToSelector:upd2]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(scene, upd2, immutable, nil);
            SPLog(@"bg: %@ sent2", bundleID);
            return YES;
        }
    } @catch (NSException *e) { SPLog(@"bg ex %@", e.reason); }
    return NO;
}

+ (BOOL)suspendAppToBackground:(NSString *)bundleID {
    if (!bundleID.length) return NO;
    // 优先：SBMainWorkspace 的 home 请求
    Class wsCls = NSClassFromString(@"SBMainWorkspace");
    id ws = wsCls ? SPMsg0(wsCls, @"sharedInstance") : nil;
    for (NSString *sn in @[@"requestForTransitionToHomeScreen", @"_handleHomeButtonSinglePress"]) {
        SEL sel = NSSelectorFromString(sn);
        if (ws && [ws respondsToSelector:sel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(ws, sel); SPLog(@"suspend via %@", sn); return YES; }
            @catch (__unused NSException *e) {}
        }
    }
    // 次选：SBUIController 的菜单键
    Class uic = NSClassFromString(@"SBUIController");
    id ui = uic ? SPMsg0(uic, @"sharedInstance") : nil;
    for (NSString *sn in @[@"handleHomeButtonSinglePressUp", @"clickedMenuButton"]) {
        SEL sel = NSSelectorFromString(sn);
        if (ui && [ui respondsToSelector:sel]) {
            @try { ((void (*)(id, SEL))objc_msgSend)(ui, sel); SPLog(@"suspend via SBUIController.%@", sn); return YES; }
            @catch (__unused NSException *e) {}
        }
    }
    SPLog(@"suspend: no API available");
    return NO;
}

// 让一个「有 scene 但不出画面」的 App 重新渲染：
// 切到后台再切回前台。contentState=0 说明它释放了渲染，只有重新激活才会重建。
+ (void)forceRecycleApp:(NSString *)bundleID {
    if (!bundleID.length) return;
    SPLog(@"recycle %@ (scene contentState stuck)", bundleID);
    @try {
        // 1) 先让它退到后台
        Class uic = NSClassFromString(@"SBUIController");
        id ui = uic ? SPMsg0(uic, @"sharedInstance") : nil;
        for (NSString *sn in @[@"handleHomeButtonSinglePressUp", @"clickedMenuButton"]) {
            SEL sel = NSSelectorFromString(sn);
            if (ui && [ui respondsToSelector:sel]) {
                ((void (*)(id, SEL))objc_msgSend)(ui, sel);
                break;
            }
        }
        // 2) 隔 0.35s 再拉回前台，触发 scene 重建
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self reactivateApp:bundleID];
            SPLog(@"recycle %@ reactivated", bundleID);
        });
    } @catch (NSException *e) { SPLog(@"recycle ex %@", e.reason); }
}

+ (BOOL)activateApp:(NSString *)bundleID windowScene:(UIWindowScene *)scene completion:(void (^)(BOOL))completion {
    id app = [self applicationProxyForBundleID:bundleID];
    if (!app) return NO;
    Class wsCls = NSClassFromString(@"SBMainWorkspace");
    id ws = wsCls ? SPMsg0(wsCls, @"sharedInstance") : nil;
    SEL sel = NSSelectorFromString(@"activateApplication:withResult:");
    if (ws && [ws respondsToSelector:sel]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(ws, sel, app, ^(BOOL ok) {
            if (completion) completion(ok);
        });
        return YES;
    }
    return NO;
}

#pragma mark - 规范 IFBSceneSettings

static id SPGet(id o, NSString *name) {
    @try { return SPMsg0(o, name); }
    @catch (__unused NSException *e) { return nil; }
}

static BOOL SPSetI(id o, NSString *name, NSInteger v) {
    @try {
        if (!SPABI(o, name, "v", 1, @encode(NSInteger))) return NO;
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(o, NSSelectorFromString(name), v);
        return YES;
    } @catch (__unused NSException *e) { return NO; }
}

// 把面板尺寸写进 scene settings。不推这一下，画面仍按全屏渲染，host 是空的。
// 工厂出来的 SBDeviceApplicationSceneView 默认不渲染：必须关掉占位内容、
// 关掉「宿主缩放上下文」、并把 displayMode 设成 4（活画面）。
// 少任何一步，视图就是一块黑（0.3.1 的黑屏就是这么来的）。
static BOOL SPPrepareSceneHost(UIView *v, NSMutableString *diag) {
    if (!v) return NO;
    @try {
        SEL ph = NSSelectorFromString(@"setPlaceholderContentEnabled:");
        BOOL hasPh = SPABI(v, @"setPlaceholderContentEnabled:", "v", 1, @encode(BOOL));
        if (hasPh) ((void (*)(id, SEL, BOOL))objc_msgSend)(v, ph, NO);
        SEL rz = NSSelectorFromString(@"setResizesHostedContext:");
        BOOL hasRz = SPABI(v, @"setResizesHostedContext:", "v", 1, @encode(BOOL));
        if (hasRz) ((void (*)(id, SEL, BOOL))objc_msgSend)(v, rz, NO);
        SEL dm = NSSelectorFromString(@"setDisplayMode:animationFactory:completion:");
        BOOL hasDm = SPABI(v, @"setDisplayMode:animationFactory:completion:", "v", 3, @encode(NSInteger), "@", "@");
        if (hasDm) ((void (*)(id, SEL, NSInteger, id, id))objc_msgSend)(v, dm, 4, nil, nil);
        v.userInteractionEnabled = YES;
        if (diag) [diag appendFormat:@" prep=ph%d rz%d dm%d", hasPh, hasRz, hasDm];
        return hasDm;
    } @catch (NSException *e) {
        if (diag) [diag appendFormat:@" prep!(%@)", e.reason];
        return NO;
    }
}

static BOOL SPSubmitSceneSettings(id scene, CGSize pane, NSInteger orient, NSString **diag) {
    if (diag) *diag = nil;
    if (!scene || !isfinite(pane.width) || !isfinite(pane.height) || pane.width < 2 || pane.height < 2) {
        if (diag) *diag = @"invalid-scene-size";
        return NO;
    }
    @try {
        id settings = SPGet(scene, @"settings");
        id desired = SPMsg0(settings, @"mutableCopy");
        if (!SPABI(desired, @"setFrame:", "v", 1, @encode(CGRect))) {
            if (diag) *diag = @"no-setFrame-ABI";
            return NO;
        }
        SPVoidRect1(desired, @"setFrame:", CGRectMake(0, 0, pane.width, pane.height));
        // 方向仅在接管时写一次，来源是 scene 已有设置；拖动不触碰方向/远端尺寸。
        SPSetI(desired, @"setInterfaceOrientation:", orient);
        SPVoid1B(desired, @"setForeground:", YES);
        SPVoid1B(desired, @"setBackgrounded:", NO);
        id immutable = SPMsg0(desired, @"copy");
        if (!immutable) { if (diag) *diag = @"immutable-nil"; return NO; }
        NSString *three = @"updateSettings:withTransitionContext:completion:";
        if (SPABI(scene, three, "v", 3, "@", "@", "@")) {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(scene, NSSelectorFromString(three), immutable, nil, nil);
            if (diag) *diag = @"sent3";
            return YES;
        }
        NSString *two = @"updateSettings:withTransitionContext:";
        if (SPABI(scene, two, "v", 2, "@", "@")) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(scene, NSSelectorFromString(two), immutable, nil);
            if (diag) *diag = @"sent2";
            return YES;
        }
        if (diag) *diag = @"no-updateSettings-ABI";
    } @catch (NSException *e) {
        if (diag) *diag = [NSString stringWithFormat:@"ex %@", e.reason];
    }
    return NO;
}

#pragma mark - 实例

- (instancetype)initWithBundleID:(NSString *)bundleID {
    if ((self = [super init])) {
        _bundleID = [bundleID copy];
        _requester = [SPHostRequester new];
    }
    return self;
}

- (void)installSnapshot:(UIImage *)snapshot {
    if (!SPHostOnMain(@"installSnapshot:") || !snapshot) return;
    // 允许先 installSnapshot 后 attach；原版底部快照在 container 尚为空时直接丢掉。
    _pendingSnapshot = snapshot;
    [self layoutSnapshot];
}

- (void)layoutSnapshot {
    UIView *container = _containerView;
    if (!container || !_pendingSnapshot) return;
    if (!_snapshotView) {
        _snapshotView = [[UIImageView alloc] initWithImage:_pendingSnapshot];
        _snapshotView.contentMode = UIViewContentModeScaleAspectFill;
        _snapshotView.clipsToBounds = YES;
        _snapshotView.userInteractionEnabled = NO;
        _snapshotView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    } else {
        _snapshotView.image = _pendingSnapshot;
    }
    if (_snapshotView.superview != container) [container insertSubview:_snapshotView atIndex:0];
    _snapshotView.frame = container.bounds;
    _snapshotView.hidden = _live;
    _snapshotActive = !_live;
    if (_hostView) _hostView.hidden = !_live;
}



// 工厂可能直接返回 UIView，也可能返回 view controller；后者必须被强引用住，
// 否则 VC 一释放就把 view 一起带走（Duo 0.7.x 踩过）。
- (UIView *)viewFromResultRetaining:(id)result {
    if ([result isKindOfClass:[UIView class]]) return (UIView *)result;
    // 只对真正的 VC 做 view 生命周期管理，不向任意有同名 selector 的对象猜返回类型。
    if ([result isKindOfClass:[UIViewController class]]) {
        UIView *v = [(UIViewController *)result view];
        if ([v isKindOfClass:[UIView class]]) { self.controller = result; return v; }
    }
    return nil;
}

static id SPNewSceneView(id handle, NSString *name, CGSize ref, NSInteger orient, id requester) {
    BOOL separate = [name containsString:@"contentOrientation:"];
    BOOL abi = separate ? SPABI(handle, name, "@", 4, @encode(CGSize), @encode(NSInteger), @encode(NSInteger), "@")
                        : SPABI(handle, name, "@", 3, @encode(CGSize), @encode(NSInteger), "@");
    if (!abi) return nil;
    NSMethodSignature *sig = [handle methodSignatureForSelector:NSSelectorFromString(name)];
    if (!sig) return nil;
    @try {
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.target = handle;
        inv.selector = NSSelectorFromString(name);
        [inv setArgument:&ref atIndex:2];
        [inv setArgument:&orient atIndex:3];
        if (separate) [inv setArgument:&orient atIndex:4];
        [inv setArgument:&requester atIndex:separate ? 5 : 4];
        [inv invoke];
        void *raw = NULL;
        [inv getReturnValue:&raw];
        // 这两条已知工厂都属于 new 方法族，返回 +1；NSInvocation 本身不替 ARC 消费它。
        // 原版 __unsafe_unretained 读取后遗失 +1，导致每次交换/重试泄漏呈现者。
        return (__bridge_transfer id)raw;
    } @catch (NSException *e) {
        SPLog(@"factory %@ ex %@", name, e.reason);
        return nil;
    }
}


// 把按 referenceSize 渲染的 host 铺满 container（cover）：取 MAX(sx,sy)，
// 画面覆盖整个容器，超出的部分由容器 clipsToBounds 裁掉。
// 之前用 MIN（contain）导致画面只占 60% 宽、四周大片留白 —— 用户明确要求铺满。
static void SPFitHostView(UIView *host, UIView *container, CGSize reference) {
    if (!host || !container || !isfinite(reference.width) || !isfinite(reference.height) ||
        reference.width < 2 || reference.height < 2) return;
    CGSize target = container.bounds.size;
    if (!isfinite(target.width) || !isfinite(target.height) || target.width < 2 || target.height < 2) return;

    // 照抄 Duo 的写法（DPSceneHost.m layoutHostView）：
    // bounds 固定为 scene 原尺寸（全屏），center 对齐容器中心，
    // 再用 transform 做 cover 缩放，溢出由容器 clipsToBounds 裁掉。
    // 关键点：全程不改 scene 尺寸，纯视觉变换 —— 拖动零延迟、不黑屏。
    host.transform = CGAffineTransformIdentity;
    host.bounds = CGRectMake(0, 0, reference.width, reference.height);
    host.center = CGPointMake(CGRectGetMidX(container.bounds), CGRectGetMidY(container.bounds));
    CGFloat scale = MAX(target.width / reference.width, target.height / reference.height);
    container.clipsToBounds = YES;
    host.transform = CGAffineTransformMakeScale(scale, scale);
}

- (BOOL)attachToContainer:(UIView *)container inWindowScene:(UIWindowScene *)windowScene {
    if (!SPHostOnMain(@"attachToContainer:")) return NO;
    [self cancelPendingAttachments];
    _callbacksEnabled = YES;
    return [self tryAttachToContainer:container inWindowScene:windowScene];
}

- (BOOL)tryAttachToContainer:(UIView *)container inWindowScene:(UIWindowScene *)windowScene {
    // 在第一次尝试之前检查；不能像原版先创建宿主，失败后才检查退出状态。
    UIWindow *window = container.window;
    if (!container || !window || window.hidden ||
        (windowScene && window.windowScene != windowScene)) return NO;
    if (_live && _hostView && _hostView.superview == container) return YES;
    // 已建但尚无内容：只按当前代际轮询，不能重复创建第二个呈现者。
    if (_attached && _hostView && _scene && SPBool0(_scene, @"isValid")) {
        _containerView = container;
        [self layoutSnapshot];
        [self waitForContentReady:8 generation:_attachmentGeneration];
        return YES;
    }
    [self releaseHostedPresentation];
    _containerView = container;
    [self layoutSnapshot];
    _lastDiag = nil;

    id scene = [SPHost fbSceneForBundleID:_bundleID];
    if (!scene) { _lastDiag = @"no-scene"; return NO; }
    _scene = scene;

    // 全屏参考尺寸：决不以面板 bounds 作远端 frame。方向取 scene 自身已知设置，
    // 不请求系统旋转，也不根据 UIScreen 当前横竖猜着覆盖已有 scene 方向。
    CGSize ref = window.screen.bounds.size;
    if (!isfinite(ref.width) || !isfinite(ref.height) || ref.width < 2 || ref.height < 2) {
        _lastDiag = @"invalid-display-size";
        _scene = nil;
        return NO;
    }
    id settings = SPMsg0(scene, @"settings");
    NSInteger orient = SPInt0(settings, @"interfaceOrientation");
    if (orient < UIInterfaceOrientationPortrait || orient > UIInterfaceOrientationLandscapeRight) {
        CGRect frame = SPRect0(settings, @"frame");
        CGSize basis = frame.size.width >= 2 && frame.size.height >= 2 ? frame.size : ref;
        orient = basis.width > basis.height ? UIInterfaceOrientationLandscapeRight : UIInterfaceOrientationPortrait;
    }
    BOOL landscape = UIInterfaceOrientationIsLandscape(orient);
    if (landscape != (ref.width > ref.height)) ref = CGSizeMake(ref.height, ref.width);
    _referenceSize = ref;
    _lastSize = CGSizeZero;

    // 2) 拥有工厂的句柄
    id handle = [SPHost sceneHandleForScene:scene];
    if (!handle) handle = scene;      // 有些机型 scene 自己就暴露工厂

    // 3) 只使用新建的、自有呈现者；不得把系统 switcher 的 sceneView 摘来并 invalidate。
    _requester = [SPHostRequester new];
    NSString *factory = @"newSceneViewWithReferenceSize:contentOrientation:containerOrientation:hostRequester:";
    id result = SPNewSceneView(handle, factory, ref, orient, _requester);
    UIView *host = [self viewFromResultRetaining:result];
    if (host) _lastDiag = @"factory-sep";
    if (!host) {
        factory = @"newSceneViewWithReferenceSize:orientation:hostRequester:";
        result = SPNewSceneView(handle, factory, ref, orient, _requester);
        host = [self viewFromResultRetaining:result];
        if (host) _lastDiag = @"factory-orient";
    }
    _handle = handle;
    if (!host || host.superview || ([self.controller isKindOfClass:[UIViewController class]] &&
                                  [(UIViewController *)self.controller parentViewController])) {
        _lastDiag = host ? @"factory-returned-owned-view" : @"no-compatible-factory";
        SPLog(@"attach FAIL %@ diag=%@ handle=%@", _bundleID, _lastDiag,
              handle ? NSStringFromClass([handle class]) : @"nil");
        _controller = nil;
        _handle = nil;
        _scene = nil;
        return NO;
    }
    _hostView = host;

    // 4) 改任何 scene 几何值之前保存可恢复基准；不允许无法恢复的接管。
    if (![self captureOriginalSettings]) {
        _lastDiag = @"cannot-capture-original-geometry";
        [self releaseHostedPresentation];
        return NO;
    }
    NSMutableString *prepDiag = [NSMutableString string];
    if (!SPPrepareSceneHost(host, prepDiag)) {
        _lastDiag = [@"cannot-prepare-live-host" stringByAppendingString:prepDiag];
        [self releaseHostedPresentation];
        return NO;
    }
    _registrationToken = [NSObject new];
    SPHostRegisterHostedScene(scene, _registrationToken);
    NSString *sub = nil;
    // 在发送之前登记归属，第一次 updateSettings 就能被 pin hook 正确处理。
    BOOL sent = SPSubmitSceneSettings(scene, ref, orient, &sub);
    _lastDiag = [NSString stringWithFormat:@"%@%@/%@", _lastDiag, prepDiag, sub ?: @"-"];
    if (!sent) {
        [self releaseHostedPresentation];
        return NO;
    }

    // 全屏参考画面以 cover 缩放到面板。VC 工厂结果要同时保活并完成 containment。
    if (!container.backgroundColor || CGColorGetAlpha(container.backgroundColor.CGColor) < 0.01)
        container.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];
    UIViewController *vc = [_controller isKindOfClass:[UIViewController class]] ? _controller : nil;
    UIViewController *parent = SPFindAncestorVC(container);
    if (vc && parent && parent != vc) [parent addChildViewController:vc];
    host.autoresizingMask = UIViewAutoresizingNone;
    host.userInteractionEnabled = YES;
    [container addSubview:host];
    if (vc.parentViewController) [vc didMoveToParentViewController:vc.parentViewController];
    [container layoutIfNeeded];
    SPFitHostView(host, container, _referenceSize);
    _attached = YES;
    _live = SPSceneHasContent(scene);
    [self layoutSnapshot];
    SPLog(@"attach %@ %@ diag=%@ view=%@ bounds=%@", _live ? @"live" : @"waiting", _bundleID,
          _lastDiag, NSStringFromClass([host class]), NSStringFromCGRect(host.bounds));
    // 即使没有快照也检查就绪，不能只在装有快照时才轮询。
    [self waitForContentReady:8 generation:_attachmentGeneration];
    return YES;
}

- (void)cancelPendingAttachments {
    if (!SPHostOnMain(@"cancelPendingAttachments")) return;
    _attachmentGeneration++;
    _contentPolling = NO;
    _callbacksEnabled = NO;
}

- (void)attachWhenReady:(UIView *)container inWindowScene:(UIWindowScene *)windowScene
                attempts:(NSInteger)attempts interval:(NSTimeInterval)interval {
    if (!SPHostOnMain(@"attachWhenReady:")) return;
    [self cancelPendingAttachments];
    _callbacksEnabled = YES;
    if (!container) return;
    _containerView = container;
    [self layoutSnapshot];
    if (!isfinite(interval) || interval <= 0) interval = 0.4;
    [self attemptAttachToContainer:container inWindowScene:windowScene attempts:MAX(0, attempts)
                         interval:MAX(0.05, interval) generation:_attachmentGeneration];
}

- (void)attemptAttachToContainer:(UIView *)container inWindowScene:(UIWindowScene *)windowScene
                     attempts:(NSInteger)attempts interval:(NSTimeInterval)interval generation:(NSUInteger)generation {
    if (generation != _attachmentGeneration || !container || _containerView != container ||
        !container.window || container.window.hidden ||
        (windowScene && container.window.windowScene != windowScene)) return;
    if ([self tryAttachToContainer:container inWindowScene:windowScene]) return;
    if (attempts <= 0) { SPLog(@"attach gave up %@ (%@)", _bundleID, _lastDiag); return; }
    __weak typeof(self) wself = self;
    __weak UIView *wc = container;
    __weak UIWindowScene *ws = windowScene;
    __weak UIWindow *ww = container.window;
    NSTimeInterval delay = MIN(interval, 30.0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(wself) self = wself;
        UIView *current = wc;
        if (!self || generation != self->_attachmentGeneration || !current || !ww ||
            current != self->_containerView || current.window != ww || ww.hidden ||
            (windowScene && !ws)) return;
        [self attemptAttachToContainer:current inWindowScene:ws attempts:attempts - 1
                             interval:interval generation:generation];
    });
}

- (BOOL)moveToContainer:(UIView *)container {
    if (!SPHostOnMain(@"moveToContainer:") || !container.window || container.window.hidden) return NO;
    [self cancelPendingAttachments];
    _containerView = container;
    _lastSize = CGSizeZero;
    [self layoutSnapshot];
    if (!_attached || !_hostView) {
        // scene 尚未建立的面板同样可以交换：旧容器上的重试失效，新容器接着等待。
        [self attachWhenReady:container inWindowScene:container.window.windowScene attempts:8 interval:1.5];
        return YES;
    }
    UIViewController *vc = [_controller isKindOfClass:[UIViewController class]] ? _controller : nil;
    UIViewController *parent = SPFindAncestorVC(container);
    BOOL changeParent = vc && parent != vc && vc.parentViewController != parent;
    if (changeParent) {
        if (vc.parentViewController) {
            [vc willMoveToParentViewController:nil];
            [_hostView removeFromSuperview];
            [vc removeFromParentViewController];
        }
        if (parent) [parent addChildViewController:vc];
    }
    [container addSubview:_hostView];
    if (changeParent && parent) [vc didMoveToParentViewController:parent];
    [container layoutIfNeeded];
    SPFitHostView(_hostView, container, _referenceSize);
    [self refreshLiveness];
    [self waitForContentReady:8 generation:_attachmentGeneration];
    return YES;
}

- (void)setFrameSize:(CGSize)size {
    if (!_containerView) return;
    CGSize r = CGSizeMake(round(size.width), round(size.height));
    if (r.width < 2 || r.height < 2) return;
    if (CGSizeEqualToSize(r, _lastSize)) return;
    _lastSize = r;
    // ⚠️ 这里不再向 scene 推任何 settings。
    // 拖动时只需要把 hostView 重新等比缩放贴进容器（纯本地变换，零跨进程开销）。
    // 推半屏 settings 会被系统判为非法帧并杀掉 App 进程，这就是之前拖动黑屏的根因。
    if (_hostView && _containerView) {
        SPFitHostView(_hostView, _containerView, _referenceSize);
    }
    _snapshotView.frame = _containerView.bounds;
}

// 所有延迟回调同时核对 generation、scene、host、container、window，不能污染后一次挂载。
- (void)waitForContentReady:(NSInteger)tries generation:(NSUInteger)generation {
    UIView *host = _hostView;
    UIView *container = _containerView;
    UIWindow *window = container.window;
    if (_contentPolling || generation != _attachmentGeneration || !_attached || !host ||
        !window || window.hidden || host.superview != container || _live) return;
    if (tries <= 0) { SPLog(@"content never ready: %@", _bundleID); return; }
    _contentPolling = YES;
    __weak typeof(self) wself = self;
    __weak UIView *wh = host;
    __weak UIView *wc = container;
    __weak UIWindow *ww = window;
    __weak id ws = _scene;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(wself) self = wself;
        if (!self || generation != self->_attachmentGeneration) return;
        UIView *currentHost = wh;
        UIView *currentContainer = wc;
        UIWindow *currentWindow = ww;
        if (!self->_attached || !currentHost || !currentContainer || !currentWindow ||
            currentWindow.hidden || currentHost != self->_hostView || currentContainer != self->_containerView ||
            currentHost.superview != currentContainer || currentContainer.window != currentWindow || ws != self->_scene) {
            self->_contentPolling = NO;
            return;
        }
        // refresh 时保留 polling 标记，避免它另起一条轮询链。
        BOOL ready = [self refreshLiveness];
        self->_contentPolling = NO;
        if (!ready) [self waitForContentReady:tries - 1 generation:generation];
        else SPLog(@"content ready: %@", self->_bundleID);
    });
}

- (BOOL)refreshLiveness {
    if (!SPHostOnMain(@"refreshLiveness")) return NO;
    BOOL ready = NO;
    @try {
        ready = _attached && _hostView && _hostView.superview == _containerView &&
                _containerView.window && !_containerView.window.hidden && SPSceneHasContent(_scene);
    } @catch (NSException *e) { SPLog(@"content check %@ ex %@", _bundleID, e.reason); }
    _live = ready;
    _snapshotActive = !ready && _snapshotView != nil;
    _snapshotView.hidden = ready;
    // 没快照时保留宿主可见以便它后续出画面，不把黑屏永久 hidden 住。
    _hostView.hidden = _snapshotActive;
    if (!ready && !_contentPolling) [self waitForContentReady:8 generation:_attachmentGeneration];
    return ready;
}

- (BOOL)captureOriginalSettings {
    if (_touchedSettings && _originalSettings[@"frame"]) return YES;
    @try {
        NSDictionary *shared = SPRepairOriginalSettingsForScene(_scene);
        if (shared) {
            _originalSettings = shared;
        } else {
            id settings = SPGet(_scene, @"settings");
            if (!SPABI(settings, @"frame", @encode(CGRect), 0)) return NO;
            CGRect frame = SPRect0(settings, @"frame");
            if (!isfinite(frame.origin.x) || !isfinite(frame.origin.y) ||
                !isfinite(frame.size.width) || !isfinite(frame.size.height) ||
                frame.size.width < 2 || frame.size.height < 2) return NO;
            NSMutableDictionary *original = [NSMutableDictionary dictionaryWithObject:[NSValue valueWithCGRect:frame] forKey:@"frame"];
            if (SPABI(settings, @"interfaceOrientation", @encode(NSInteger), 0))
                original[@"orientation"] = @(SPInt0(settings, @"interfaceOrientation"));
            _originalSettings = [original copy];
        }
        SPRepairRecordSceneSettings(_scene, _originalSettings);
        _touchedSettings = YES;
        SPLog(@"scene %@ captured frame=%@", _bundleID, NSStringFromCGRect([_originalSettings[@"frame"] CGRectValue]));
        return YES;
    } @catch (NSException *e) { SPLog(@"capture settings ex %@", e.reason); }
    return NO;
}

- (void)restoreOriginalSceneSettings {
    if (!SPHostOnMain(@"restoreOriginalSceneSettings")) return;
    [self cancelPendingAttachments];
    [self restoreSavedGeometry];
}

- (void)restoreSavedGeometry {
    // 恢复前先撤销本 owner 的前台 pin；否则 updateSettings hook 会把恢复再次前台化。
    SPHostUnregisterHostedScene(_scene, _registrationToken);
    _registrationToken = nil;
    if (!_touchedSettings || !_scene || !_originalSettings) return;
    if (SPHostSceneIsHosted(_scene)) {
        // 旧 owner 退出时仍有新 owner：基准留在 repair 台账给最后一个 owner 恢复。
        SPLog(@"scene %@ restore deferred (another owner)", _bundleID);
        _touchedSettings = NO;
        _originalSettings = nil;
        return;
    }
    NSString *diag = nil;
    BOOL sent = SPRepairRestoreSceneGeometry(_scene, _originalSettings, &diag);
    SPLog(@"scene %@ restore %@ (%@)", _bundleID, sent ? @"submitted" : @"pending", diag ?: @"-");
    if (sent) {
        SPRepairForgetScene(_scene);
        _touchedSettings = NO;
        _originalSettings = nil;
    }
    // updateSettings 是异步事务；不在同一栈回读旧 frame 后再猜着发第二个全屏事务。
}

- (void)releaseHostedPresentation {
    SPHostUnregisterHostedScene(_scene, _registrationToken);
    _registrationToken = nil;
    _attached = NO;
    _live = NO;
    // requester / handle 在 invalidate 完成前保持强引用。
    @try { SPReleaseSceneView(_hostView, _controller); }
    @catch (NSException *e) { SPLog(@"detach view ex %@", e.reason); }
    _hostView = nil;
    _controller = nil;
    // 未显式 restore 的交换旧路径、替换失败、dealloc 前 detach 也不能丢失恢复机会。
    [self restoreSavedGeometry];
    _scene = nil;
    _handle = nil;
    _requester = nil;
    _originalSettings = nil;
    _touchedSettings = NO;
    _referenceSize = CGSizeZero;
    _lastSize = CGSizeZero;
}

- (void)detach {
    if (!SPHostOnMain(@"detach")) return;
    [self cancelPendingAttachments];
    [self releaseHostedPresentation];
    [_snapshotView removeFromSuperview];
    _snapshotView = nil;
    _pendingSnapshot = nil;
    _snapshotActive = NO;
    _containerView = nil;
}

- (void)dealloc {
    // 正常路径由 owner 在主线程显式 detach。遗漏时也必须撤登记并放弃呈现权，
    // 且不能像原版直接在任意释放线程触碰 UIKit。
    SPHostUnregisterHostedScene(_scene, _registrationToken);
    UIView *view = _hostView;
    UIImageView *snapshot = _snapshotView;
    id scene = _scene;
    NSDictionary *original = _touchedSettings ? _originalSettings : nil;
    NSArray *resources = @[_controller ?: NSNull.null, _requester ?: NSNull.null, _handle ?: NSNull.null];
    void (^cleanup)(void) = ^{
        @try { SPReleaseSceneView(view, resources.firstObject); [snapshot removeFromSuperview]; }
        @catch (NSException *e) { SPLog(@"host dealloc cleanup ex %@", e.reason); }
        if (original && !SPHostSceneIsHosted(scene)) {
            NSString *diag = nil;
            if (SPRepairRestoreSceneGeometry(scene, original, &diag)) SPRepairForgetScene(scene);
        }
    };
    if ([NSThread isMainThread]) cleanup();
    else dispatch_async(dispatch_get_main_queue(), cleanup);
}

@end